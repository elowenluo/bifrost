#!/usr/bin/env bash
set -uo pipefail

# Regression tests for helm-publish-index.sh, the step of helm-release.yml that
# builds the Helm repository index this fork publishes to GitHub Pages (TXE-4820).
#
# What went wrong before: the step downloaded the UPSTREAM (maximhq) Pages index
# and `helm repo index --merge`d it, then published with keep_files: false. Each
# fork release therefore replaced the fork's own chart history with upstream's:
# fork-only versions vanished, overlapping versions were redirected to upstream
# tarballs, and a rerun of an already-published version re-indexed a freshly
# packaged tarball whose digest no longer matched the GitHub release asset the
# entry pointed at. The release URL was also hardcoded to a previous owner.
#
# Everything here runs against local fixtures: charts packaged on the fly, a bare
# git repository standing in for origin, and release assets that are just files.
# No network, no GitHub, no Pages push.
#
# Usage: ./helm-publish-index.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/helm-publish-index.sh"
WORKFLOW="${SCRIPT_DIR}/../helm-release.yml"

for tool in helm git tar diff; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool not installed: $tool" >&2
    exit 1
  fi
done
if [ ! -x "$TARGET" ]; then
  echo "FAIL: $TARGET is missing or not executable" >&2
  exit 1
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/helm-publish-index.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# Keep the user's git identity, signing and hooks out of the fixtures, and keep
# macOS tar from adding AppleDouble entries helm rejects.
export COPYFILE_DISABLE=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

FORK_REPO="txehq/bifrost"
FORK_DL="https://github.com/${FORK_REPO}/releases/download"
UPSTREAM_DL="https://github.com/maximhq/bifrost/releases/download"
PRE_TRANSFER_DL="https://github.com/capsohq/bifrost/releases/download"

passed=0
failed=0

ok() {
  echo "  ok - $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL: $1" >&2
  failed=$((failed + 1))
}

check() { # description command...
  local desc="$1"
  shift
  if "$@"; then ok "$desc"; else fail "$desc"; fi
}

not() { ! "$@"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# A git shim for failure injection, first on PATH only where a case asks for
# it. FAKE_GIT_FAIL_LS_TREE makes `git ls-tree` fail after everything before it
# succeeded; FAKE_GIT_BEFORE_PUSH runs a script right before a `git push` is
# forwarded, which lands an external write in the narrowest possible window
# (git forbids ref updates from inside a pre-receive hook, so a hook cannot do
# this). Everything else goes to the real git.
REAL_GIT="$(command -v git)"
export REAL_GIT
FAKE_BIN="$ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/git" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  ls-tree)
    if [ -n "${FAKE_GIT_FAIL_LS_TREE:-}" ]; then
      echo "fatal: unable to read tree (injected failure)" >&2
      exit 128
    fi ;;
  push)
    if [ -n "${FAKE_GIT_BEFORE_PUSH:-}" ]; then
      hook="$FAKE_GIT_BEFORE_PUSH"
      unset FAKE_GIT_BEFORE_PUSH
      bash "$hook" || exit 99
    fi ;;
esac
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$FAKE_BIN/git"

# make_chart VERSION MARKER OUTDIR -> path of the packaged tarball.
# MARKER lands in a template so two packages of the same version can differ in
# content, which is what a forgotten Chart.yaml bump looks like.
make_chart() {
  local version="$1" marker="$2" out="$3"
  local src="$ROOT/src/$version-$marker"
  mkdir -p "$src/templates" "$out"
  cat >"$src/Chart.yaml" <<EOF
apiVersion: v2
name: bifrost
description: fixture chart
type: application
version: $version
appVersion: "1.0.0"
EOF
  cat >"$src/templates/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fixture
data:
  marker: "$marker"
EOF
  helm package "$src" -d "$out" >/dev/null || return 1
  echo "$out/bifrost-$version.tgz"
}

# index_field INDEX VERSION FIELD -> the field's scalar, or the urls list items.
index_field() {
  awk -v want="$2" -v field="$3" '
    function emit(  i) { if (ver == want) for (i = 1; i <= n; i++) print vals[i] }
    /^  - / { emit(); ver = ""; n = 0; inlist = "" }
    /^    [A-Za-z]+:/ {
      key = $1; sub(":", "", key)
      inlist = ($2 == "") ? key : ""
      if (key == field && $2 != "") vals[++n] = $2
      if (key == "version") ver = $2
    }
    /^    - / { if (inlist == field) { v = $0; sub(/^    - /, "", v); vals[++n] = v } }
    END { emit() }
  ' "$1"
}

index_versions() { # INDEX -> sorted "version" lines
  awk '/^    version: / { print $2 }' "$1" | sort
}

# ---------------------------------------------------------------------------
# Fixtures: the fork's existing published history, built with helm itself so the
# layout is exactly what the release pipeline will meet.
#   1.0.0  fork-only: upstream never shipped it
#   1.1.0  overlap: the fork index inherited upstream's entry (upstream URL)
#   1.2.0  published by the fork under its pre-transfer owner name
# ---------------------------------------------------------------------------

FORK_ONLY=$(make_chart 1.0.0 fork-only "$ROOT/pkg/1.0.0") || exit 1
OVERLAP=$(make_chart 1.1.0 overlap "$ROOT/pkg/1.1.0") || exit 1
PRE_TRANSFER=$(make_chart 1.2.0 pre-transfer "$ROOT/pkg/1.2.0") || exit 1

mkdir -p "$ROOT/fx/s1" "$ROOT/fx/s2" "$ROOT/fx/s3"
cp "$FORK_ONLY" "$ROOT/fx/s1/"
helm repo index "$ROOT/fx/s1" --url "$FORK_DL/helm-chart-v1.0.0" >/dev/null || exit 1
cp "$OVERLAP" "$ROOT/fx/s2/"
helm repo index "$ROOT/fx/s2" --url "$UPSTREAM_DL/helm-chart-v1.1.0" --merge "$ROOT/fx/s1/index.yaml" >/dev/null || exit 1
cp "$PRE_TRANSFER" "$ROOT/fx/s3/"
helm repo index "$ROOT/fx/s3" --url "$PRE_TRANSFER_DL/helm-chart-v1.2.0" --merge "$ROOT/fx/s2/index.yaml" >/dev/null || exit 1
FORK_INDEX="$ROOT/fork-index.yaml"
cp "$ROOT/fx/s3/index.yaml" "$FORK_INDEX"

if [ "$(index_versions "$FORK_INDEX" | tr '\n' ' ')" != "1.0.0 1.1.0 1.2.0 " ]; then
  echo "FAIL: fixture index did not build as expected" >&2
  index_versions "$FORK_INDEX" >&2
  exit 1
fi

# The upstream index the old step merged: shares 1.1.0, carries a newer
# upstream-only 1.3.0, and knows nothing of the fork-only 1.0.0.
UPSTREAM_ONLY=$(make_chart 1.3.0 upstream-only "$ROOT/pkg/1.3.0") || exit 1
mkdir -p "$ROOT/fx/u1" "$ROOT/fx/u2"
cp "$OVERLAP" "$ROOT/fx/u1/"
helm repo index "$ROOT/fx/u1" --url "$UPSTREAM_DL/helm-chart-v1.1.0" >/dev/null || exit 1
cp "$UPSTREAM_ONLY" "$ROOT/fx/u2/"
helm repo index "$ROOT/fx/u2" --url "$UPSTREAM_DL/helm-chart-v1.3.0" --merge "$ROOT/fx/u1/index.yaml" >/dev/null || exit 1
mkdir -p "$ROOT/upstream"
UPSTREAM_INDEX="$ROOT/upstream/index.yaml"
cp "$ROOT/fx/u2/index.yaml" "$UPSTREAM_INDEX"

# make_origin NAME MODE [INDEX] -> path of a bare repo standing in for origin.
#   MODE: absent      no gh-pages branch at all
#         empty       gh-pages exists but holds no index.yaml
#         index       gh-pages holds helm-charts/index.yaml copied from INDEX
make_origin() {
  local name="$1" mode="$2" index="${3:-}"
  local bare="$ROOT/origin-$name.git"
  git init -q --bare "$bare" || return 1
  if [ "$mode" != "absent" ]; then
    local seed="$ROOT/seed-$name"
    git init -q "$seed" || return 1
    (
      cd "$seed" || exit 1
      git checkout -q -b gh-pages
      : >.nojekyll
      mkdir -p helm-charts unrelated
      echo "keep me" >unrelated/page.html
      if [ "$mode" = "index" ]; then cp "$index" helm-charts/index.yaml; fi
      git add -A
      git commit -q -m seed
      git push -q "$bare" gh-pages
    ) || return 1
  fi
  echo "$bare"
}

# run_case NAME ORIGIN VERSION CANONICAL LOCAL [extra args...]
# Runs the script from a fresh clone whose origin is ORIGIN. Sets RC, OUT, LOG.
run_case() {
  local name="$1" origin="$2" version="$3" canonical="$4" local_tgz="$5"
  shift 5
  local work="$ROOT/work-$name"
  git init -q "$work" || return 1
  git -C "$work" remote add origin "$origin"
  OUT="$ROOT/out-$name.yaml"
  LOG="$ROOT/log-$name.txt"
  (
    cd "$work" || exit 1
    "$TARGET" \
      --chart-name bifrost \
      --chart-version "$version" \
      --release-tag "helm-chart-v$version" \
      --canonical-chart "$canonical" \
      --local-chart "$local_tgz" \
      --repository "$FORK_REPO" \
      --server-url https://github.com \
      --remote origin \
      --publish-branch gh-pages \
      --index-path helm-charts/index.yaml \
      --output "$OUT" \
      "$@"
  ) >"$LOG" 2>&1
  RC=$?
}

entry_preserved() { # VERSION: the output entry matches the fixture entry exactly
  local v="$1"
  [ "$(index_field "$OUT" "$v" digest)" = "$(index_field "$FORK_INDEX" "$v" digest)" ] &&
    [ "$(index_field "$OUT" "$v" urls)" = "$(index_field "$FORK_INDEX" "$v" urls)" ] &&
    [ "$(index_field "$OUT" "$v" created)" = "$(index_field "$FORK_INDEX" "$v" created)" ]
}

# ---------------------------------------------------------------------------
echo "# new release on top of existing fork history"
NEW=$(make_chart 1.4.0 new "$ROOT/pkg/1.4.0") || exit 1
ORIGIN=$(make_origin history index "$FORK_INDEX") || exit 1
run_case new-release "$ORIGIN" 1.4.0 "$NEW" "$NEW" --base-sha-output "$ROOT/base-new-release"
check "exits 0" [ "$RC" -eq 0 ]
check "writes the index" [ -s "$OUT" ]
check "records the publish branch revision the index was read from" \
  [ "$(cat "$ROOT/base-new-release" 2>/dev/null)" = "$(git -C "$ROOT/seed-history" rev-parse gh-pages)" ]
check "fork-only 1.0.0 survives untouched" entry_preserved 1.0.0
check "overlapping 1.1.0 keeps its original (upstream) entry" entry_preserved 1.1.0
check "pre-transfer 1.2.0 keeps its original URL and digest" entry_preserved 1.2.0
check "upstream-only 1.3.0 is not imported" [ -z "$(index_field "$OUT" 1.3.0 digest)" ]
check "new 1.4.0 entry is present" [ -n "$(index_field "$OUT" 1.4.0 digest)" ]
check "new entry digest is the release asset's sha256" \
  [ "$(index_field "$OUT" 1.4.0 digest)" = "$(sha256_of "$NEW")" ]
check "new entry URL is derived from the repository identity" \
  [ "$(index_field "$OUT" 1.4.0 urls)" = "$FORK_DL/helm-chart-v1.4.0/bifrost-1.4.0.tgz" ]
check "no entry points at a previous owner for the new release" \
  not grep -q "capsohq/bifrost/releases/download/helm-chart-v1.4.0" "$OUT"
check "version set is history plus the new release" \
  [ "$(index_versions "$OUT" | tr '\n' ' ')" = "1.0.0 1.1.0 1.2.0 1.4.0 " ]

# ---------------------------------------------------------------------------
echo "# repository identity drives the release URL"
ORIGIN=$(make_origin identity index "$FORK_INDEX") || exit 1
run_case identity "$ORIGIN" 1.4.0 "$NEW" "$NEW" --repository other-org/bifrost-fork --server-url https://ghe.example.invalid
check "exits 0" [ "$RC" -eq 0 ]
check "URL follows --server-url and --repository" \
  [ "$(index_field "$OUT" 1.4.0 urls)" = "https://ghe.example.invalid/other-org/bifrost-fork/releases/download/helm-chart-v1.4.0/bifrost-1.4.0.tgz" ]

# ---------------------------------------------------------------------------
echo "# first release: no publish branch yet"
ORIGIN=$(make_origin first-absent absent) || exit 1
run_case first-absent "$ORIGIN" 1.4.0 "$NEW" "$NEW" --base-sha-output "$ROOT/base-first-absent"
check "exits 0" [ "$RC" -eq 0 ]
check "records that no publish branch existed" [ "$(cat "$ROOT/base-first-absent" 2>/dev/null)" = "none" ]
check "index holds exactly the new release" \
  [ "$(index_versions "$OUT" | tr '\n' ' ')" = "1.4.0 " ]
check "new entry digest is the release asset's sha256" \
  [ "$(index_field "$OUT" 1.4.0 digest)" = "$(sha256_of "$NEW")" ]

echo "# first release: publish branch exists but has no index yet"
ORIGIN=$(make_origin first-empty empty) || exit 1
run_case first-empty "$ORIGIN" 1.4.0 "$NEW" "$NEW" --base-sha-output "$ROOT/base-first-empty"
check "exits 0" [ "$RC" -eq 0 ]
check "records the publish branch revision even without an index" \
  [ "$(cat "$ROOT/base-first-empty" 2>/dev/null)" = "$(git -C "$ROOT/seed-first-empty" rev-parse gh-pages)" ]
check "index holds exactly the new release" \
  [ "$(index_versions "$OUT" | tr '\n' ' ')" = "1.4.0 " ]

# ---------------------------------------------------------------------------
echo "# rerun of an already-published version"
# The release asset is the tarball the index was built from. The local package
# has identical content but different bytes - a rerun on another day, another
# helm build - which is exactly what used to replace the digest.
mkdir -p "$ROOT/rerun"
tar -xzf "$PRE_TRANSFER" -C "$ROOT/rerun"
tar -czf "$ROOT/rerun/bifrost-1.2.0.tgz" -C "$ROOT/rerun" bifrost
REPACK="$ROOT/rerun/bifrost-1.2.0.tgz"
check "fixture sanity: repackaged bytes differ from the release asset" \
  [ "$(sha256_of "$REPACK")" != "$(sha256_of "$PRE_TRANSFER")" ]
ORIGIN=$(make_origin rerun index "$FORK_INDEX") || exit 1
run_case rerun "$ORIGIN" 1.2.0 "$PRE_TRANSFER" "$REPACK"
check "exits 0" [ "$RC" -eq 0 ]
check "index is byte-identical to the published one" cmp -s "$OUT" "$FORK_INDEX"
check "1.2.0 digest still matches the release asset" \
  [ "$(index_field "$OUT" 1.2.0 digest)" = "$(sha256_of "$PRE_TRANSFER")" ]
check "1.2.0 URL is not rewritten" \
  [ "$(index_field "$OUT" 1.2.0 urls)" = "$PRE_TRANSFER_DL/helm-chart-v1.2.0/bifrost-1.2.0.tgz" ]

# ---------------------------------------------------------------------------
echo "# conflicts: published version whose content changed"
CHANGED=$(make_chart 1.2.0 changed-without-bump "$ROOT/pkg/1.2.0-changed") || exit 1
ORIGIN=$(make_origin drift index "$FORK_INDEX") || exit 1
run_case drift "$ORIGIN" 1.2.0 "$PRE_TRANSFER" "$CHANGED"
check "chart content differing from the release asset fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

echo "# conflicts: index entry disagrees with the release asset"
sed "s/$(index_field "$FORK_INDEX" 1.2.0 digest)/0000000000000000000000000000000000000000000000000000000000000000/" \
  "$FORK_INDEX" >"$ROOT/fork-index-baddigest.yaml"
ORIGIN=$(make_origin baddigest index "$ROOT/fork-index-baddigest.yaml") || exit 1
run_case baddigest "$ORIGIN" 1.2.0 "$PRE_TRANSFER" "$PRE_TRANSFER"
check "mismatched published digest fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

echo "# conflicts: release asset is not the version being released"
ORIGIN=$(make_origin wrongasset index "$FORK_INDEX") || exit 1
run_case wrongasset "$ORIGIN" 1.4.0 "$UPSTREAM_ONLY" "$NEW"
check "asset/version mismatch fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

# ---------------------------------------------------------------------------
echo "# fetch failures are errors, never an empty index"
run_case unreachable "$ROOT/does-not-exist.git" 1.4.0 "$NEW" "$NEW"
check "unreachable origin fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

printf '<!DOCTYPE html>\n<html><head><title>Site not found</title></head><body>404</body></html>\n' \
  >"$ROOT/index-404.html"
ORIGIN=$(make_origin html index "$ROOT/index-404.html") || exit 1
run_case html "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "an HTML error page where the index should be fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

head -c 120 "$FORK_INDEX" >"$ROOT/index-truncated.yaml"
ORIGIN=$(make_origin truncated index "$ROOT/index-truncated.yaml") || exit 1
run_case truncated "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "a truncated index fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

: >"$ROOT/index-empty.yaml"
ORIGIN=$(make_origin emptyfile index "$ROOT/index-empty.yaml") || exit 1
run_case emptyfile "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "an empty index file fails rather than passing as a first release" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

echo "# a failed tree lookup is never read as an absent index"
ORIGIN=$(make_origin lstree index "$FORK_INDEX") || exit 1
FAKE_GIT_FAIL_LS_TREE=1 PATH="$FAKE_BIN:$PATH" run_case lstree "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "an unreadable tree after a successful fetch fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

# ---------------------------------------------------------------------------
echo "# published entries are preserved whole, not as a projection"
# A field helm's typed load re-emits differently: an empty value is omitted on
# the way out, so a merge through helm drops it while name, version, digest and
# urls all still match. (Unknown fields are rejected by helm's strict loader;
# that case is below.)
awk '/^    version: 1\.0\.0$/ { print "    home: \"\"" } { print }' "$FORK_INDEX" >"$ROOT/fork-index-extra.yaml"
check "fixture sanity: the extra field sits inside the 1.0.0 entry" \
  grep -q '^    home: ""$' "$ROOT/fork-index-extra.yaml"
check "fixture sanity: helm loads the index but drops the field on re-emission" \
  not grep -q '^    home: ""$' <(mkdir -p "$ROOT/reemit" && helm repo index "$ROOT/reemit" --merge "$ROOT/fork-index-extra.yaml" >/dev/null 2>&1 && cat "$ROOT/reemit/index.yaml")
ORIGIN=$(make_origin extra-add index "$ROOT/fork-index-extra.yaml") || exit 1
run_case extra-add "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "adding a release cannot silently drop a published entry's field" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]
ORIGIN=$(make_origin extra-rerun index "$ROOT/fork-index-extra.yaml") || exit 1
run_case extra-rerun "$ORIGIN" 1.2.0 "$PRE_TRANSFER" "$PRE_TRANSFER"
check "rerun of a published version keeps the index byte for byte, extra field included" \
  cmp -s "$OUT" "$ROOT/fork-index-extra.yaml"

awk '/^    version: 1\.0\.0$/ { print "    x-fork-note: keep" } { print }' "$FORK_INDEX" >"$ROOT/fork-index-unknown.yaml"
ORIGIN=$(make_origin unknown index "$ROOT/fork-index-unknown.yaml") || exit 1
run_case unknown "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "an entry field helm cannot load fails rather than being guessed around" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]

echo "# index structure is validated explicitly"
awk -v d="$(index_field "$FORK_INDEX" 1.1.0 digest)" '$0 == "    digest: " d { next } { print }' \
  "$FORK_INDEX" >"$ROOT/fork-index-nodigest.yaml"
check "fixture sanity: 1.1.0 has no digest" [ -z "$(index_field "$ROOT/fork-index-nodigest.yaml" 1.1.0 digest)" ]
ORIGIN=$(make_origin nodigest index "$ROOT/fork-index-nodigest.yaml") || exit 1
run_case nodigest "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "a published entry without a digest fails" [ "$RC" -ne 0 ]
check "no index is written on failure" [ ! -e "$OUT" ]
printf 'apiVersion: v1\nentries: {}\n' >"$ROOT/index-noentries.yaml"
ORIGIN=$(make_origin noentries index "$ROOT/index-noentries.yaml") || exit 1
run_case noentries "$ORIGIN" 1.4.0 "$NEW" "$NEW"
check "a valid index with no entries yet is accepted" [ "$RC" -eq 0 ]
check "index holds exactly the new release" \
  [ "$(index_versions "$OUT" | tr '\n' ' ')" = "1.4.0 " ]

# ---------------------------------------------------------------------------
echo "# publication is a compare-and-swap on the recorded revision"
PUBLISH="${SCRIPT_DIR}/helm-publish-pages.sh"
check "publish script exists and is executable" [ -x "$PUBLISH" ]

origin_head() { git --git-dir="$1" rev-parse --verify --quiet refs/heads/gh-pages; }
origin_show() { git --git-dir="$1" show "refs/heads/gh-pages:$2" 2>/dev/null; }
origin_has() { [ -n "$(git --git-dir="$1" ls-tree --name-only refs/heads/gh-pages -- "$2" 2>/dev/null)" ]; }

# run_publish NAME ORIGIN BASE-RECORD PUBLISH-DIR -> RC, PLOG
run_publish() {
  local name="$1" origin="$2" base="$3" dir="$4"
  local work="$ROOT/publish-$name"
  git init -q "$work" || return 1
  git -C "$work" remote add origin "$origin"
  printf '%s\n' "$base" >"$ROOT/publish-base-$name"
  PLOG="$ROOT/publish-log-$name.txt"
  (
    cd "$work" || exit 1
    "$PUBLISH" \
      --remote origin \
      --publish-branch gh-pages \
      --base-sha-file "$ROOT/publish-base-$name" \
      --publish-dir "$dir" \
      --destination-dir helm-charts \
      --message "deploy: test $name"
  ) >"$PLOG" 2>&1
  RC=$?
}

# What the release job publishes: the chart sources, the local package and the
# built index, mirroring publish_dir: ./helm-charts.
PUBDIR="$ROOT/pubdir"
mkdir -p "$PUBDIR/bifrost"
cp "$ROOT/out-new-release.yaml" "$PUBDIR/index.yaml"
cp "$ROOT/src/1.4.0-new/Chart.yaml" "$PUBDIR/bifrost/Chart.yaml"
cp "$NEW" "$PUBDIR/"

ORIGIN=$(make_origin publish index "$FORK_INDEX") || exit 1
(cd "$ROOT/seed-publish" && echo stale >helm-charts/stale.tgz && git add -A && git commit -qm stale && git push -q "$ORIGIN" gh-pages) || exit 1
BASE=$(origin_head "$ORIGIN")
run_publish normal "$ORIGIN" "$BASE" "$PUBDIR"
check "exits 0" [ "$RC" -eq 0 ]
check "publish branch advanced by one commit whose parent is the recorded revision" \
  [ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/gh-pages^" 2>/dev/null)" = "$BASE" ]
check "published index is the built one" cmp -s <(origin_show "$ORIGIN" helm-charts/index.yaml) "$PUBDIR/index.yaml"
check "chart sources are published under the destination" origin_has "$ORIGIN" helm-charts/bifrost/Chart.yaml
check "the package is published under the destination" origin_has "$ORIGIN" helm-charts/bifrost-1.4.0.tgz
check "stale files under the destination are removed" not origin_has "$ORIGIN" helm-charts/stale.tgz
check "content outside the destination is preserved" [ "$(origin_show "$ORIGIN" unrelated/page.html)" = "keep me" ]
check ".nojekyll at the root is preserved" origin_has "$ORIGIN" .nojekyll

echo "# publishing the same content again is a no-op"
run_publish again "$ORIGIN" "$(origin_head "$ORIGIN")" "$PUBDIR"
check "exits 0" [ "$RC" -eq 0 ]
check "no commit is pushed when nothing changed" \
  [ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/gh-pages^")" = "$BASE" ]

echo "# first publication creates the branch"
ORIGIN=$(make_origin publish-first absent) || exit 1
run_publish first "$ORIGIN" none "$PUBDIR"
check "exits 0" [ "$RC" -eq 0 ]
check "creates the publish branch with a single root commit" \
  [ "$(git --git-dir="$ORIGIN" rev-list --count refs/heads/gh-pages 2>/dev/null)" = "1" ]
check "published index is the built one" cmp -s <(origin_show "$ORIGIN" helm-charts/index.yaml) "$PUBDIR/index.yaml"
check "adds .nojekyll at the root" origin_has "$ORIGIN" .nojekyll

echo "# an external write after the index read is never overwritten"
ORIGIN=$(make_origin publish-moved index "$FORK_INDEX") || exit 1
BASE=$(origin_head "$ORIGIN")
(cd "$ROOT/seed-publish-moved" && echo corrected >helm-charts/index.yaml && git commit -qam external && git push -q "$ORIGIN" gh-pages) || exit 1
J=$(origin_head "$ORIGIN")
run_publish moved "$ORIGIN" "$BASE" "$PUBDIR"
check "a publish branch that moved after the read fails" [ "$RC" -ne 0 ]
check "the external change is untouched" [ "$(origin_head "$ORIGIN")" = "$J" ]
check "the failure tells the operator to re-run" grep -qi 're-run' "$PLOG"

echo "# an external write landing right before the push is never overwritten"
ORIGIN=$(make_origin publish-race index "$FORK_INDEX") || exit 1
BASE=$(origin_head "$ORIGIN")
cat >"$ROOT/race-hook.sh" <<EOF
cd "$ROOT/seed-publish-race" && echo corrected >helm-charts/index.yaml && git commit -qam external && git push -q "$ORIGIN" gh-pages
EOF
FAKE_GIT_BEFORE_PUSH="$ROOT/race-hook.sh" PATH="$FAKE_BIN:$PATH" run_publish race "$ORIGIN" "$BASE" "$PUBDIR"
check "the push is rejected" [ "$RC" -ne 0 ]
check "the external change is untouched" [ "$(origin_show "$ORIGIN" helm-charts/index.yaml)" = "corrected" ]
check "the failure tells the operator to re-run" grep -qi 're-run' "$PLOG"

echo "# a branch created by another writer during a first publication is never overwritten"
ORIGIN=$(make_origin publish-appear absent) || exit 1
cat >"$ROOT/appear-hook.sh" <<EOF
git init -q "$ROOT/appear-seed" && cd "$ROOT/appear-seed" && git checkout -q -b gh-pages && echo external >README && git add -A && git commit -qm external && git push -q "$ORIGIN" gh-pages
EOF
FAKE_GIT_BEFORE_PUSH="$ROOT/appear-hook.sh" PATH="$FAKE_BIN:$PATH" run_publish appear "$ORIGIN" none "$PUBDIR"
check "the push is rejected" [ "$RC" -ne 0 ]
check "the other writer's branch is untouched" [ "$(origin_show "$ORIGIN" README)" = "external" ]

echo "# failures to ask the remote or a bad record never publish"
run_publish unreachable "$ROOT/does-not-exist.git" "$BASE" "$PUBDIR"
check "unreachable origin fails" [ "$RC" -ne 0 ]
ORIGIN=$(make_origin publish-record index "$FORK_INDEX") || exit 1
K=$(origin_head "$ORIGIN")
run_publish garbage "$ORIGIN" "not-a-revision" "$PUBDIR"
check "a malformed base record fails" [ "$RC" -ne 0 ]
run_publish empty "$ORIGIN" "" "$PUBDIR"
check "an empty base record fails" [ "$RC" -ne 0 ]
check "nothing was published by the failed attempts" [ "$(origin_head "$ORIGIN")" = "$K" ]

# ---------------------------------------------------------------------------
echo "# three successive releases: a stale attempt fails, nothing is lost"
# Two runs read the index at the same revision; the second to publish must fail
# rather than drop the first's version, and its rebuilt attempt must carry it.
B=$(make_chart 1.5.0 second "$ROOT/pkg/1.5.0") || exit 1
C=$(make_chart 1.6.0 third "$ROOT/pkg/1.6.0") || exit 1
ORIGIN=$(make_origin publish-three index "$FORK_INDEX") || exit 1
run_case three-a "$ORIGIN" 1.4.0 "$NEW" "$NEW" --base-sha-output "$ROOT/base-three-a"
OUT_A="$OUT"
run_case three-b "$ORIGIN" 1.5.0 "$B" "$B" --base-sha-output "$ROOT/base-three-b"
OUT_B="$OUT"
mkdir -p "$ROOT/pub-a" "$ROOT/pub-b" "$ROOT/pub-b2" "$ROOT/pub-c"
cp "$OUT_A" "$ROOT/pub-a/index.yaml"
run_publish three-a "$ORIGIN" "$(cat "$ROOT/base-three-a")" "$ROOT/pub-a"
check "first release publishes" [ "$RC" -eq 0 ]
cp "$OUT_B" "$ROOT/pub-b/index.yaml"
run_publish three-b-stale "$ORIGIN" "$(cat "$ROOT/base-three-b")" "$ROOT/pub-b"
check "a release built on the stale revision fails instead of dropping 1.4.0" [ "$RC" -ne 0 ]
origin_show "$ORIGIN" helm-charts/index.yaml >"$ROOT/three-after-a.yaml"
check "1.4.0 is still published" [ -n "$(index_field "$ROOT/three-after-a.yaml" 1.4.0 digest)" ]
run_case three-b2 "$ORIGIN" 1.5.0 "$B" "$B" --base-sha-output "$ROOT/base-three-b2"
cp "$OUT" "$ROOT/pub-b2/index.yaml"
run_publish three-b2 "$ORIGIN" "$(cat "$ROOT/base-three-b2")" "$ROOT/pub-b2"
check "the rebuilt second release publishes" [ "$RC" -eq 0 ]
run_case three-c "$ORIGIN" 1.6.0 "$C" "$C" --base-sha-output "$ROOT/base-three-c"
cp "$OUT" "$ROOT/pub-c/index.yaml"
run_publish three-c "$ORIGIN" "$(cat "$ROOT/base-three-c")" "$ROOT/pub-c"
check "the third release publishes" [ "$RC" -eq 0 ]
origin_show "$ORIGIN" helm-charts/index.yaml >"$ROOT/three-final.yaml"
check "all three releases and the history are published" \
  [ "$(index_versions "$ROOT/three-final.yaml" | tr '\n' ' ')" = "1.0.0 1.1.0 1.2.0 1.4.0 1.5.0 1.6.0 " ]

# ---------------------------------------------------------------------------
echo "# the release job is gated and publishes by compare-and-swap"
check "release job is gated on the release refs before any write" \
  grep -qE "^    if: github\.ref == 'refs/heads/main'" "$WORKFLOW"
check "workflow publishes through the compare-and-swap script" grep -q 'helm-publish-pages.sh' "$WORKFLOW"
check "workflow no longer deploys through a clone-and-replace action" not grep -q 'actions-gh-pages' "$WORKFLOW"
check "workflow has no concurrency group that could cancel a queued release" \
  not grep -qE '^concurrency:' "$WORKFLOW"

# ---------------------------------------------------------------------------
echo "# publication stays with the repository owner"
check "script carries no upstream or previous-owner identity" \
  not grep -qE 'maximhq|capsohq' "$TARGET"
check "workflow runs the script" grep -q 'helm-publish-index.sh' "$WORKFLOW"
check "workflow no longer downloads a Pages index over HTTP" \
  not grep -qE 'github\.io/[^ ]*index\.yaml' "$WORKFLOW"
check "workflow release URLs are not hardcoded to an owner" \
  not grep -qE 'github\.com/(maximhq|capsohq)/bifrost/releases/download' "$WORKFLOW"
check "workflow OCI targets are not hardcoded to an owner" \
  not grep -qE 'oci://[^ ]*/(maximhq|capsohq)' "$WORKFLOW"
check "workflow egress allowlist does not open upstream Pages" \
  not grep -q 'maximhq.github.io' "$WORKFLOW"

echo ""
if [ "$failed" -ne 0 ]; then
  echo "$failed failed, $passed passed" >&2
  exit 1
fi
echo "$passed passed"
