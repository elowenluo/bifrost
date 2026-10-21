#!/usr/bin/env bash
set -uo pipefail

# Tests that the multi-arch manifest scripts never re-push a published version tag.
#
# create-docker-manifest.sh and create-docker-manifest-ubi9.sh compose v<version>
# (v<version>-ubi9) and the moving latest (latest-ubi9) tag from the architecture images,
# by digest. A release run can fail after v<version> is published, and the retry must not
# replace it: release detection passes PUBLISH_VERSION_TAG=true only when the registry
# confirmed that tag absent. The architecture images are reused by digest either way, so
# latest still lands on the same images.
#
# Runs both real scripts with a fake docker (testdata/fake-docker) first on PATH; nothing
# reaches a registry.
#
# Usage: ./docker-manifest-publish.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

AMD64_DIGEST="sha256:$(printf 'a%.0s' $(seq 1 64))"
ARM64_DIGEST="sha256:$(printf 'b%.0s' $(seq 1 64))"

# The fake docker (see testdata/fake-docker): architecture digests are a... and b....
cp "$SCRIPT_DIR/testdata/fake-docker" "$WORK/bin/docker"

passed=0
failed=0
CASE=""
LOG=""
RC=0

# run_manifest <script> <version> [PUBLISH_VERSION_TAG value | "unset"]
run_manifest() {
  local script="$1" version="$2" publish="$3"
  CASE="$(basename "$script") $version PUBLISH_VERSION_TAG=$publish"
  LOG="$WORK/$(printf '%s' "$CASE" | tr -c 'A-Za-z0-9' '_').log"
  : > "$LOG"
  local -a env_args=(PATH="$WORK/bin:$PATH" DOCKER_LOG="$LOG" REGISTRY=ghcr.io ACCOUNT=txehq)
  [ "$publish" != "unset" ] && env_args+=(PUBLISH_VERSION_TAG="$publish")
  env -u PUBLISH_VERSION_TAG "${env_args[@]}" bash "$SCRIPT_DIR/$script" "$version" > "$WORK/out" 2>&1
  RC=$?
}

ok() {
  echo "  ok - $CASE: $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL: $CASE: $1" >&2
  failed=$((failed + 1))
}

# expect_pushes <tag>...: the run succeeded and pushed exactly these tags, each composed
# from the two architecture digests.
expect_pushes() {
  local want got tag
  if [ "$RC" -ne 0 ]; then
    fail "exited $RC ($(tail -2 "$WORK/out" | tr '\n' ' '))"
    return
  fi
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  got=$(sed -n 's#^manifest push ghcr.io/txehq/bifrost:##p' "$LOG" | sort)
  if [ "$want" = "$got" ]; then
    ok "pushed exactly [$(echo $want)]"
  else
    fail "pushed [$(echo $got)], expected [$(echo $want)]"
  fi
  for tag in "$@"; do
    [ -z "$tag" ] && continue
    if grep -qxF "manifest create ghcr.io/txehq/bifrost:${tag} ghcr.io/txehq/bifrost@${AMD64_DIGEST} ghcr.io/txehq/bifrost@${ARM64_DIGEST}" "$LOG"; then
      ok "$tag composed from the architecture digests"
    else
      fail "$tag was not composed from the architecture digests"
    fi
  done
}

expect_refused() {
  if [ "$RC" -eq 0 ]; then
    fail "exited 0 without a valid PUBLISH_VERSION_TAG"
  elif grep -q "^manifest \(create\|push\)" "$LOG"; then
    fail "touched a manifest without a valid PUBLISH_VERSION_TAG"
  else
    ok "refused before touching any manifest"
  fi
}

echo "Docker manifest publication"

for pair in "create-docker-manifest.sh:" "create-docker-manifest-ubi9.sh:-ubi9"; do
  script="${pair%%:*}"
  suffix="${pair#*:}"

  run_manifest "$script" 2.3.2 true
  expect_pushes "v2.3.2${suffix}" "latest${suffix}"

  # A retry after v2.3.2 was published: leave it alone, still move latest.
  run_manifest "$script" 2.3.2 false
  expect_pushes "latest${suffix}"

  run_manifest "$script" 2.3.2-rc1 true
  expect_pushes "v2.3.2-rc1${suffix}"

  run_manifest "$script" 2.3.2-rc1 false
  expect_pushes ""

  run_manifest "$script" 2.3.2 unset
  expect_refused

  run_manifest "$script" 2.3.2 ""
  expect_refused

  run_manifest "$script" 2.3.2 "TRUE"
  expect_refused
done

echo ""
if [ "$failed" -ne 0 ]; then
  echo "$failed failed, $passed passed" >&2
  exit 1
fi
echo "$passed passed"
