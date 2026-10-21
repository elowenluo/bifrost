#!/usr/bin/env bash
set -uo pipefail

# Regression tests for helm-publish-oci.sh, the step of helm-release.yml that
# publishes the released chart to the repository owner's GHCR namespace.
#
# What went wrong before: the OCI push only ran when the GitHub release did not
# exist at the start of the run and tolerated every error. A run that created
# the release and then failed (Pages, login, push) could never publish the OCI
# artifact on a rerun, and a failed push looked like success. A first fix then
# read any "not found" in a failed `helm pull` as absence, although that pull
# also downloads content: a manifest that exists with a blob that cannot be
# fetched would have been pushed over. A second fix read a manifest 404 as
# absence, although GHCR answers the same way for a repository the token
# cannot see: absence needs the repository's authenticated tag listing to
# confirm visibility, exactly as PR #6 decided for image tags, and a package
# that does not exist yet is bootstrapped deliberately, never by this script.
#
# The registry is faked twice over: a curl shim (PR #6's testdata/fake-ghcr-curl)
# answers the token exchange and the manifest lookup, and a helm shim scripts
# `helm pull` and records every `helm push`; every other helm subcommand goes
# to the real binary. Nothing reaches a registry and no credential is real.
#
# Usage: ./helm-publish-oci.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/helm-publish-oci.sh"
WORKFLOW="${SCRIPT_DIR}/../helm-release.yml"

for tool in helm jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool not installed: $tool" >&2
    exit 1
  fi
done
if [ ! -x "$TARGET" ]; then
  echo "FAIL: $TARGET is missing or not executable" >&2
  exit 1
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/helm-publish-oci.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export COPYFILE_DISABLE=1

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

# make_chart VERSION MARKER OUTDIR -> path of the packaged tarball.
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

CANON=$(make_chart 1.2.0 released "$ROOT/pkg/canonical") || exit 1
OTHER=$(make_chart 1.2.0 something-else "$ROOT/pkg/other") || exit 1
WRONG=$(make_chart 1.0.0 released "$ROOT/pkg/wrong") || exit 1
if [ "$(sha256_of "$CANON")" = "$(sha256_of "$OTHER")" ]; then
  echo "FAIL: fixture charts should differ" >&2
  exit 1
fi

# Sentinels: a scenario fails if either shows up in a push or pull argv.
JOB_TOKEN="ghs_SENTINELjobtoken0123456789"
BEARER="SENTINELbearer456+/="
export GITHUB_TOKEN="$JOB_TOKEN"

REAL_HELM="$(command -v helm)"
export REAL_HELM
FAKE_BIN="$ROOT/bin"
mkdir -p "$FAKE_BIN"

# The registry's HTTP side: PR #6's fake curl, answering from $FAKE_DIR/token
# and $FAKE_DIR/manifest ("<http status> <curl exit code> <body>" per line).
cp "$SCRIPT_DIR/testdata/fake-ghcr-curl" "$FAKE_BIN/curl"
cat >"$FAKE_BIN/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "sleep $*" >>"$FAKE_DIR/sleep.log"
FAKE

# The registry's content side. `pull` answers come from $FAKE_DIR/pull, one per
# line, in order (the last line repeats): "bloberror", "file:<path>" (deliver
# that tarball) or "pushed" (deliver whatever the last push sent). `push` is
# logged and fails when $FAKE_DIR/push.fail exists.
cat >"$FAKE_BIN/helm" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  pull)
    printf '%s\n' "$*" >>"$FAKE_DIR/pull.log"
    n=$(( $(cat "$FAKE_DIR/pull.n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$FAKE_DIR/pull.n"
    total=$(wc -l <"$FAKE_DIR/pull")
    [ "$n" -gt "$total" ] && n="$total"
    answer=$(sed -n "${n}p" "$FAKE_DIR/pull")
    dest="."
    while [ $# -gt 0 ]; do
      case "$1" in -d|--destination) dest="$2"; shift 2 ;; *) shift ;; esac
    done
    case "$answer" in
      bloberror)
        echo 'Error: failed to perform "Copy" on source: ghcr.io/fake/helm-charts/bifrost@sha256:0000: not found' >&2
        exit 1 ;;
      file:*)
        mkdir -p "$dest" && cp "${answer#file:}" "$dest/" && echo "Pulled: fake" ;;
      pushed)
        mkdir -p "$dest" && cp "$(cat "$FAKE_DIR/pushed")" "$dest/" && echo "Pulled: fake" ;;
      *)
        echo "fake helm: unexpected pull answer '$answer'" >&2
        exit 99 ;;
    esac ;;
  push)
    printf '%s\n' "$*" >>"$FAKE_DIR/push.log"
    if [ -f "$FAKE_DIR/push.fail" ]; then
      echo 'Error: unexpected status from HEAD request to https://ghcr.io/v2/fake/helm-charts/bifrost/blobs/sha256:0: 403 Forbidden' >&2
      exit 1
    fi
    printf '%s\n' "$2" >"$FAKE_DIR/pushed"
    echo "Pushed: fake"
    echo "Digest: sha256:0000000000000000000000000000000000000000000000000000000000000000" ;;
  *)
    exec "$REAL_HELM" "$@" ;;
esac
FAKE
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/sleep" "$FAKE_BIN/helm"

TOKEN_OK="200 0 {\"token\":\"${BEARER}\"}"
TOKEN_REFUSED='401 0 {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}'
MANIFEST_OK='200 0 {"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}'
MANIFEST_UNKNOWN='404 0 {"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'
NAME_UNKNOWN='404 0 {"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
MANIFEST_DENIED='403 0 {"errors":[{"code":"DENIED","message":"denied"}]}'
MANIFEST_404_HTML='404 0 <html>not json</html>'
MANIFEST_NETWORK='000 7 '
TAGS_OK='200 0 {"name":"txehq/helm-charts/bifrost","tags":["1.0.0"]}'
TAGS_NAME_UNKNOWN='404 0 {"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
TAGS_OTHER_NAME='200 0 {"name":"txehq/helm-charts/other","tags":[]}'
TAGS_DENIED='403 0 {"errors":[{"code":"DENIED","message":"denied"}]}'
TAGS_NETWORK='000 7 '

# run_oci NAME CANONICAL TOKEN-ANSWER MANIFEST-ANSWER TAGS-ANSWER PULL-ANSWERS [push-fail]
run_oci() {
  local name="$1" canonical="$2" token="$3" manifest="$4" tags="$5" pulls="$6"
  FAKE_DIR="$ROOT/fake-$name"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/calls.log"
  : >"$FAKE_DIR/argv.log"
  printf '%s\n' "$token" >"$FAKE_DIR/token"
  printf '%s\n' "$manifest" >"$FAKE_DIR/manifest"
  printf '%s\n' "$tags" >"$FAKE_DIR/tags"
  printf '%s\n' "$pulls" >"$FAKE_DIR/pull"
  if [ "${7:-}" = "push-fail" ]; then : >"$FAKE_DIR/push.fail"; fi
  LOG="$ROOT/log-$name.txt"
  FAKE_DIR="$FAKE_DIR" PATH="$FAKE_BIN:$PATH" "$TARGET" \
    --chart-name bifrost \
    --chart-version "${CHART_VERSION:-1.2.0}" \
    --canonical-chart "$canonical" \
    --registry ghcr.io \
    --owner "${OWNER:-txehq}" \
    --repository-path helm-charts \
    >"$LOG" 2>&1
  RC=$?
  PUSHES=$(wc -l <"$FAKE_DIR/push.log" 2>/dev/null | tr -d ' ')
  PUSHES=${PUSHES:-0}
  PULLS=$(wc -l <"$FAKE_DIR/pull.log" 2>/dev/null | tr -d ' ')
  PULLS=${PULLS:-0}
}

content_untouched() { [ "$PULLS" -eq 0 ] && [ "$PUSHES" -eq 0 ]; }
registry_untouched() { content_untouched && [ ! -s "$FAKE_DIR/calls.log" ]; }
owner_lookup_lowercased() {
  grep -q 'manifests/1.2.0' "$FAKE_DIR/calls.log" && grep -q '/v2/txehq/helm-charts/bifrost/' "$FAKE_DIR/calls.log"
}
no_secret_in_argv() {
  not grep -qF "$JOB_TOKEN" "$FAKE_DIR/argv.log" "$FAKE_DIR/pull.log" "$FAKE_DIR/push.log" "$LOG" 2>/dev/null &&
    not grep -qF "$BEARER" "$FAKE_DIR/argv.log" "$FAKE_DIR/pull.log" "$FAKE_DIR/push.log" "$LOG" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "# missing version is published from the canonical asset and verified"
run_oci absent "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" pushed
check "exits 0" [ "$RC" -eq 0 ]
check "looks the requested version's manifest up" \
  grep -q 'manifest https://ghcr.io/v2/txehq/helm-charts/bifrost/manifests/1.2.0' "$FAKE_DIR/calls.log"
check "pushes exactly once" [ "$PUSHES" -eq 1 ]
check "pushes the canonical asset" grep -qF -- "$CANON" "$FAKE_DIR/push.log"
check "pushes into the owner's namespace" grep -qF -- "oci://ghcr.io/txehq/helm-charts" "$FAKE_DIR/push.log"
check "confirms the repository is visible to the token before publishing" \
  grep -q 'tags https://ghcr.io/v2/txehq/helm-charts/bifrost/tags/list' "$FAKE_DIR/calls.log"
check "reads the published artifact back" [ "$PULLS" -eq 1 ]
check "pulls the chart reference with the released version" \
  grep -qE -- 'oci://ghcr.io/txehq/helm-charts/bifrost .*--version 1\.2\.0' "$FAKE_DIR/pull.log"
check "no credential reaches argv or the log" no_secret_in_argv

echo "# a repository the token cannot see is never published into"
# GHCR answers a manifest lookup the same way for a version that is absent and
# for a repository the token cannot see; only the authenticated tag listing
# tells them apart. A package that does not exist yet looks exactly like an
# invisible one and is bootstrapped deliberately, never here.
run_oci invisible "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_NAME_UNKNOWN" pushed
check "fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]
check "names the bootstrap requirement" grep -qi 'bootstrap' "$LOG"
run_oci unknownrepo "$CANON" "$TOKEN_OK" "$NAME_UNKNOWN" "$TAGS_NAME_UNKNOWN" pushed
check "a repository the registry does not know fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]
run_oci othername "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OTHER_NAME" pushed
check "a tag listing for a different repository fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]
run_oci tagsdenied "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_DENIED" pushed
check "a refused tag listing fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]
run_oci tagsnetwork "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_NETWORK" pushed
check "an unreachable tag listing fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# an identical published version is left alone"
run_oci identical "$CANON" "$TOKEN_OK" "$MANIFEST_OK" "$TAGS_OK" "file:$CANON"
check "exits 0" [ "$RC" -eq 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# a published version with different content is a conflict"
run_oci conflict "$CANON" "$TOKEN_OK" "$MANIFEST_OK" "$TAGS_OK" "file:$OTHER"
check "fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# a manifest that exists whose content cannot be fetched is never pushed over"
run_oci blobmissing "$CANON" "$TOKEN_OK" "$MANIFEST_OK" "$TAGS_OK" bloberror
check "fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# anything but a definite answer about the manifest is a failure, never absence"
run_oci denied "$CANON" "$TOKEN_OK" "$MANIFEST_DENIED" "$TAGS_OK" pushed
check "a refused manifest lookup fails" [ "$RC" -ne 0 ]
check "touches the content side not at all" content_untouched
run_oci notjson "$CANON" "$TOKEN_OK" "$MANIFEST_404_HTML" "$TAGS_OK" pushed
check "a 404 without a registry error code fails" [ "$RC" -ne 0 ]
check "touches the content side not at all" content_untouched
run_oci network "$CANON" "$TOKEN_OK" "$MANIFEST_NETWORK" "$TAGS_OK" pushed
check "a network failure fails" [ "$RC" -ne 0 ]
check "touches the content side not at all" content_untouched
run_oci tokenrefused "$CANON" "$TOKEN_REFUSED" "$MANIFEST_UNKNOWN" "$TAGS_OK" pushed
check "a refused token exchange fails" [ "$RC" -ne 0 ]
check "touches the content side not at all" content_untouched
GITHUB_TOKEN="" run_oci notoken "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" pushed
check "a missing job token fails" [ "$RC" -ne 0 ]
check "touches the registry not at all" registry_untouched

echo "# publication errors fail the step"
run_oci pushfail "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" pushed push-fail
check "a failed push fails" [ "$RC" -ne 0 ]
run_oci verifyfail "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" "file:$OTHER"
check "a push whose readback differs from the asset fails" [ "$RC" -ne 0 ]
run_oci verifygone "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" bloberror
check "a push whose readback fails fails" [ "$RC" -ne 0 ]

echo "# the asset must be the version being published"
run_oci wrongasset "$WRONG" "$TOKEN_OK" "$MANIFEST_OK" "$TAGS_OK" "file:$CANON"
check "asset/version mismatch fails" [ "$RC" -ne 0 ]
check "touches the registry not at all" registry_untouched

echo "# the namespace follows the repository owner, lowercased"
OWNER=TxEhq run_oci owner "$CANON" "$TOKEN_OK" "$MANIFEST_UNKNOWN" "$TAGS_OK" pushed
check "exits 0" [ "$RC" -eq 0 ]
check "looks the manifest up under the lowercased owner" owner_lookup_lowercased
check "pushes into the lowercased owner's namespace" \
  grep -qF -- "oci://ghcr.io/txehq/helm-charts" "$FAKE_DIR/push.log"

echo "# the repository's real chart, maintainers and all"
# helm sorts keys, so a maintainer's nested `name:` precedes the top-level
# `name:` in `helm show chart`; the fixtures above carry no maintainers.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REAL_VERSION="$(awk '/^version:/ { print $2; exit }' "$REPO_ROOT/helm-charts/bifrost/Chart.yaml")"
mkdir -p "$ROOT/pkg/real"
helm package "$REPO_ROOT/helm-charts/bifrost" -d "$ROOT/pkg/real" >/dev/null 2>&1
REAL="$ROOT/pkg/real/bifrost-$REAL_VERSION.tgz"
check "fixture sanity: the real chart packages and names a maintainer" \
  grep -q '^  name: ' <(helm show chart "$REAL" 2>/dev/null)
CHART_VERSION="$REAL_VERSION" run_oci real "$REAL" "$TOKEN_OK" "$MANIFEST_OK" "$TAGS_OK" "file:$REAL"
check "the real chart is accepted as the version it is" [ "$RC" -eq 0 ]
check "an identical published real chart is left alone" [ "$PUSHES" -eq 0 ]

# ---------------------------------------------------------------------------
echo "# workflow wiring"
oci_step() { awk '/Push Helm chart as OCI artifact to GHCR/,/helm-publish-oci\.sh/' "$WORKFLOW"; }
login_step() { awk '/Login to GitHub Container Registry/,/password:/' "$WORKFLOW"; }
check "workflow runs the OCI publication script" grep -q 'helm-publish-oci.sh' "$WORKFLOW"
check "OCI publication does not depend on whether the GitHub release pre-existed" \
  not grep -q 'check-release' <(oci_step)
check "OCI publication errors are not tolerated" not grep -q 'continue-on-error' <(oci_step)
check "OCI publication gets the job token for the manifest lookup" grep -q 'GITHUB_TOKEN' <(oci_step)
check "registry login is not skipped or tolerated" \
  not grep -qE 'continue-on-error|check-release' <(login_step)
check "egress allows GHCR blob downloads" grep -q 'pkg-containers.githubusercontent.com:443' "$WORKFLOW"
check "script carries no upstream or previous-owner identity" not grep -qE 'maximhq|capsohq' "$TARGET"

echo ""
if [ "$failed" -ne 0 ]; then
  echo "$failed failed, $passed passed" >&2
  exit 1
fi
echo "$passed passed"
