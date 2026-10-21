#!/usr/bin/env bash
set -uo pipefail

# Regression tests for helm-publish-oci.sh, the step of helm-release.yml that
# publishes the released chart to the repository owner's GHCR namespace.
#
# What went wrong before: the OCI push only ran when the GitHub release did not
# exist at the start of the run and tolerated every error. A run that created
# the release and then failed (Pages, login, push) could never publish the OCI
# artifact on a rerun, and a failed push looked like success.
#
# The registry is faked: a `helm` shim first on PATH scripts the answers to
# `helm pull` and records every `helm push`; every other helm subcommand goes
# to the real binary. Nothing reaches a registry.
#
# Usage: ./helm-publish-oci.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/helm-publish-oci.sh"
WORKFLOW="${SCRIPT_DIR}/../helm-release.yml"

if ! command -v helm >/dev/null 2>&1; then
  echo "FAIL: required tool not installed: helm" >&2
  exit 1
fi
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

# The helm shim. `pull` answers come from $FAKE_DIR/pull, one per line, in order
# (the last line repeats): "notfound", "denied", "file:<path>" (deliver that
# tarball) or "pushed" (deliver whatever the last push sent). `push` is logged
# and fails when $FAKE_DIR/push.fail exists.
REAL_HELM="$(command -v helm)"
export REAL_HELM
FAKE_BIN="$ROOT/bin"
mkdir -p "$FAKE_BIN"
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
      notfound)
        echo 'Error: failed to perform "FetchReference" on source: ghcr.io/fake/helm-charts/bifrost:1.2.0: not found' >&2
        exit 1 ;;
      denied)
        echo 'Error: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Afake%2Fhelm-charts%2Fbifrost%3Apull&service=ghcr.io: 401 Unauthorized' >&2
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
chmod +x "$FAKE_BIN/helm"

# run_oci NAME CANONICAL PULL-ANSWERS [push-fail]
run_oci() {
  local name="$1" canonical="$2" answers="$3"
  FAKE_DIR="$ROOT/fake-$name"
  mkdir -p "$FAKE_DIR"
  printf '%s\n' "$answers" >"$FAKE_DIR/pull"
  if [ "${4:-}" = "push-fail" ]; then : >"$FAKE_DIR/push.fail"; fi
  LOG="$ROOT/log-$name.txt"
  FAKE_DIR="$FAKE_DIR" PATH="$FAKE_BIN:$PATH" "$TARGET" \
    --chart-name bifrost \
    --chart-version 1.2.0 \
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

# ---------------------------------------------------------------------------
echo "# missing version is published from the canonical asset and verified"
run_oci absent "$CANON" $'notfound\npushed'
check "exits 0" [ "$RC" -eq 0 ]
check "pushes exactly once" [ "$PUSHES" -eq 1 ]
check "pushes the canonical asset" grep -qF -- "$CANON" "$FAKE_DIR/push.log"
check "pushes into the owner's namespace" grep -qF -- "oci://ghcr.io/txehq/helm-charts" "$FAKE_DIR/push.log"
check "pulls the chart reference with the released version" \
  grep -qE -- 'oci://ghcr.io/txehq/helm-charts/bifrost .*--version 1\.2\.0' "$FAKE_DIR/pull.log"
check "verifies the published artifact after pushing" [ "$PULLS" -eq 2 ]

echo "# an identical published version is left alone"
run_oci identical "$CANON" "file:$CANON"
check "exits 0" [ "$RC" -eq 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# a published version with different content is a conflict"
run_oci conflict "$CANON" "file:$OTHER"
check "fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# anything but a definite 'not found' is a failure, never absence"
run_oci denied "$CANON" denied
check "a refused lookup fails" [ "$RC" -ne 0 ]
check "does not push" [ "$PUSHES" -eq 0 ]

echo "# publication errors fail the step"
run_oci pushfail "$CANON" notfound push-fail
check "a failed push fails" [ "$RC" -ne 0 ]

run_oci verifyfail "$CANON" $'notfound\nfile:'"$OTHER"
check "a push whose readback differs from the asset fails" [ "$RC" -ne 0 ]

run_oci verifygone "$CANON" $'notfound\nnotfound'
check "a push whose readback is missing fails" [ "$RC" -ne 0 ]

echo "# the asset must be the version being published"
run_oci wrongasset "$WRONG" "file:$CANON"
check "asset/version mismatch fails" [ "$RC" -ne 0 ]
registry_untouched() { [ "$PULLS" -eq 0 ] && [ "$PUSHES" -eq 0 ]; }
check "touches the registry not at all" registry_untouched

echo "# the namespace follows the repository owner, lowercased"
OWNER=TxEhq run_oci owner "$CANON" $'notfound\npushed'
check "exits 0" [ "$RC" -eq 0 ]
check "pushes into the lowercased owner's namespace" \
  grep -qF -- "oci://ghcr.io/txehq/helm-charts" "$FAKE_DIR/push.log"

# ---------------------------------------------------------------------------
echo "# workflow wiring"
oci_step() { awk '/Push Helm chart as OCI artifact to GHCR/,/helm-publish-oci\.sh/' "$WORKFLOW"; }
login_step() { awk '/Login to GitHub Container Registry/,/password:/' "$WORKFLOW"; }
check "workflow runs the OCI publication script" grep -q 'helm-publish-oci.sh' "$WORKFLOW"
check "OCI publication does not depend on whether the GitHub release pre-existed" \
  not grep -q 'check-release' <(oci_step)
check "OCI publication errors are not tolerated" not grep -q 'continue-on-error' <(oci_step)
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
