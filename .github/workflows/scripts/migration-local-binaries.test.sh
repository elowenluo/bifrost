#!/usr/bin/env bash
set -uo pipefail

# Tests the MIGRATION_LOCAL_BINARIES override in run-migration-tests.sh.
#
# The override exists so a migration run can start from the deployed fork build instead of
# upstream's npx release. An explicit mapping that cannot run (an empty path from an unset
# variable, a typo, a file without the executable bit) must fail the run: falling back to
# npx would migrate from upstream's build and still report success for the fork build.
#
# The invalid-mapping scenarios run the real script end to end with fake git, npx, docker
# and lsof first on PATH, so nothing leaves the machine; the script must stop before any of
# them is asked to start a baseline. One scenario keeps the real lsof and proves the early
# exit leaves an unrelated listener on BIFROST_PORT running. The launch scenarios run the script's own
# start_previous_bifrost against a fake binary and a fake npx.
#
# Usage: ./migration-local-binaries.test.sh
#        RUN_MIGRATION_TESTS=/path/to/other/run-migration-tests.sh ./migration-local-binaries.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${RUN_MIGRATION_TESTS:-${SCRIPT_DIR}/run-migration-tests.sh}"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
CALLS="$WORK/calls"

# Every fake records its argv; npx and docker also fail, so a scenario that reaches one
# can never pass by accident.
for tool in git npx docker; do
  cat > "$FAKE_BIN/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$CALLS"
[ "$tool" = git ] && exit 0
exit 1
EOF
  chmod +x "$FAKE_BIN/$tool"
done

# A fake lsof that sees no listeners keeps the rejection scenarios from inspecting real
# ports at all; the listener scenario below uses the real one on purpose.
FAKE_LSOF_BIN="$WORK/lsof-bin"
mkdir -p "$FAKE_LSOF_BIN"
cat > "$FAKE_LSOF_BIN/lsof" <<EOF
#!/usr/bin/env bash
echo "lsof \$*" >> "$CALLS"
exit 1
EOF
chmod +x "$FAKE_LSOF_BIN/lsof"

BASELINE="$WORK/bifrost-http-fork"
cat > "$BASELINE" <<EOF
#!/usr/bin/env bash
echo "baseline \$*" >> "$CALLS"
EOF
chmod +x "$BASELINE"
NOT_EXECUTABLE="$WORK/not-executable"
touch "$NOT_EXECUTABLE"

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# expect_rejected runs the real script with an invalid mapping and checks that it exits
# non-zero with the given message, having asked neither npx nor docker for anything.
expect_rejected() {
  local name="$1" mapping="$2" message="$3" output status
  : > "$CALLS"
  output="$(cd "$REPO_ROOT" && PATH="$FAKE_LSOF_BIN:$FAKE_BIN:$PATH" MIGRATION_TEST_VERSIONS="v2.1.1" \
    MIGRATION_LOCAL_BINARIES="$mapping" bash "$TARGET" sqlite 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    fail "$name: the run exited 0"
  fi
  if ! grep -qF "$message" <<< "$output"; then
    fail "$name: output lacks '$message'"
  fi
  if grep -qE '^(npx|docker) ' "$CALLS"; then
    fail "$name: a baseline was started: $(grep -E '^(npx|docker) ' "$CALLS" | head -1)"
  fi
}

expect_rejected "empty path" "v2.1.1=" "maps v2.1.1 to '', which is not an executable file"
expect_rejected "missing file" "v2.1.1=$WORK/absent" "which is not an executable file"
expect_rejected "not executable" "v2.1.1=$NOT_EXECUTABLE" "which is not an executable file"
expect_rejected "directory" "v2.1.1=$WORK" "which is not an executable file"
expect_rejected "no separator" "v2.1.1" "is not a version=path pair"
expect_rejected "one bad entry among good" "v2.0.0=$BASELINE v2.1.1=" "maps v2.1.1 to ''"

# A run that stops before starting any server must leave the port alone: cleanup used
# to kill whatever listened on BIFROST_PORT, which here is a listener this test owns.
for tool in lsof python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for the listener scenario"
done
if command -v lsof >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  LISTEN_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  python3 -m http.server --bind 127.0.0.1 "$LISTEN_PORT" > /dev/null 2>&1 &
  LISTENER=$!
  for _ in $(seq 1 50); do
    lsof -t -i ":$LISTEN_PORT" > /dev/null 2>&1 && break
    sleep 0.1
  done
  lsof -t -i ":$LISTEN_PORT" > /dev/null 2>&1 || fail "listener scenario: the test listener did not start"
  (cd "$REPO_ROOT" && PATH="$FAKE_BIN:$PATH" MIGRATION_TEST_VERSIONS="v2.1.1" BIFROST_PORT="$LISTEN_PORT" \
    MIGRATION_LOCAL_BINARIES="v2.1.1=" bash "$TARGET" sqlite > /dev/null 2>&1)
  if kill -0 "$LISTENER" 2>/dev/null; then
    kill "$LISTENER" 2>/dev/null
    wait "$LISTENER" 2>/dev/null
  else
    fail "listener scenario: cleanup killed a listener on BIFROST_PORT that the run never started"
  fi
fi

# The launch path: load the script's own functions, then start each kind of baseline.
functions="$(awk '/^(local_binary_for_version|start_previous_bifrost)\(\) \{$/,/^\}$/' "$TARGET")"
launch() {
  : > "$CALLS"
  PATH="$FAKE_BIN:$PATH" MIGRATION_LOCAL_BINARIES="$2" bash -c "
    log_info() { :; }
    log_error() { echo \"\$1\" >&2; }
    TEMP_DIR='$WORK' BIFROST_PORT=18999
    $functions
    start_previous_bifrost '$1' '$WORK/server.log' || exit 1
    wait \"\$BIFROST_PID\" || true
  "
}

launch v2.1.1 "v2.1.1=$BASELINE" || fail "mapped version: start_previous_bifrost failed"
grep -qx "baseline -app-dir $WORK -port 18999" "$CALLS" || fail "mapped version: the local binary did not run"
grep -q '^npx ' "$CALLS" && fail "mapped version: npx ran"

launch v2.0.0 "v2.1.1=$BASELINE"
grep -q '^npx @maximhq/bifrost --transport-version v2.0.0 ' "$CALLS" || fail "unmapped version: npx did not run"
grep -q '^baseline ' "$CALLS" && fail "unmapped version: the local binary ran"

if launch v2.1.1 "v2.1.1=" 2>/dev/null; then
  fail "empty mapping: start_previous_bifrost succeeded"
fi
grep -q '^npx ' "$CALLS" && fail "empty mapping: start_previous_bifrost fell back to npx"

# MIGRATION_FORK_IMAGES: resolve_fork_baselines against a fake registry probe (a
# ghcr-tags.sh in a fake SCRIPT_DIR) and a fake docker. The probe answers from
# FAKE_GHCR_STATES, or fails when FAKE_GHCR_FAIL is set; docker create fails when
# FAKE_DOCKER_CREATE_FAIL is set.
FAKE_SCRIPTS="$WORK/scripts"
mkdir -p "$FAKE_SCRIPTS"
cat > "$FAKE_SCRIPTS/ghcr-tags.sh" <<EOF
ghcr_tag_states() {
  echo "probe \$*" >> "$CALLS"
  [ -z "\${FAKE_GHCR_FAIL:-}" ] || return 1
  printf '%b' "\$FAKE_GHCR_STATES"
}
EOF
FORK_DOCKER_BIN="$WORK/fork-docker-bin"
mkdir -p "$FORK_DOCKER_BIN"
cat > "$FORK_DOCKER_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$CALLS"
case "\$1" in
  login) cat > /dev/null ;;
  create) [ -z "\${FAKE_DOCKER_CREATE_FAIL:-}" ] || exit 1; img="\${*: -1}"; echo "cid-\${img##*:}" ;;
  cp) [ -z "\${FAKE_DOCKER_CP_FAIL:-}" ] || exit 1; printf '#!/bin/sh\n' > "\$3" ;;
  rm) [ -z "\${FAKE_DOCKER_RM_FAIL:-}" ] || exit 1 ;;
esac
EOF
chmod +x "$FORK_DOCKER_BIN/docker"
# resolve_fork_baselines allocates with mktemp -d and the child shells below have no exit
# trap, so TMPDIR points into $WORK and the test's own cleanup removes every allocation.
RESOLVE_TMP="$WORK/tmp"
mkdir -p "$RESOLVE_TMP"
resolve_functions="$(awk '/^(local_binary_for_version|get_previous_versions|resolve_fork_baselines)\(\) \{$/,/^\}$/' "$TARGET")"
# resolve <versions> <existing mapping>: prints the resulting MIGRATION_LOCAL_BINARIES.
resolve() {
  : > "$CALLS"
  TMPDIR="$RESOLVE_TMP" PATH="$FORK_DOCKER_BIN:$PATH" MIGRATION_TEST_VERSIONS="$1" MIGRATION_LOCAL_BINARIES="$2" \
    MIGRATION_FORK_IMAGES=txehq/bifrost GITHUB_TOKEN=fake-token-value bash -c "
    set -euo pipefail
    log_info() { :; }
    log_error() { echo \"\$1\" >&2; }
    SCRIPT_DIR='$FAKE_SCRIPTS' REPO_ROOT='$REPO_ROOT' VERSIONS_TO_TEST=3 FORK_BASELINE_DIR=''
    $resolve_functions
    resolve_fork_baselines || exit 1
    echo \"\$MIGRATION_LOCAL_BINARIES\"
    for pair in \$MIGRATION_LOCAL_BINARIES; do [ -x \"\${pair#*=}\" ] || echo \"not executable: \$pair\" >&2; done
  "
}

mapping="$(FAKE_GHCR_STATES='v1.5.11 absent\nv2.1.3 present\n' resolve "v1.5.11 v2.1.3" "" 2>"$WORK/err")" \
  || fail "fork image: resolve_fork_baselines failed: $(cat "$WORK/err")"
grep -qE '^v2\.1\.3=.*/bifrost-http-v2\.1\.3$' <<< "$mapping" || fail "fork image: v2.1.3 was not mapped (got '$mapping')"
grep -q 'v1\.5\.11=' <<< "$mapping" && fail "fork image: v1.5.11 has no fork image but was mapped"
grep -q 'not executable' "$WORK/err" && fail "fork image: $(cat "$WORK/err")"
grep -qx 'docker create --pull=always ghcr.io/txehq/bifrost:v2.1.3' "$CALLS" \
  || fail "fork image: v2.1.3 was not freshly pulled ($(grep 'docker create' "$CALLS"))"
grep -qx 'docker rm -v cid-v2.1.3' "$CALLS" || fail "fork image: the extraction container was not removed with its volume"
grep -q 'docker create .*v1\.5\.11' "$CALLS" && fail "fork image: v1.5.11 was pulled"
grep -q 'fake-token-value' "$CALLS" && fail "fork image: the token reached docker's argv"

FAKE_GHCR_STATES='v2.1.3 present\n' resolve "v2.1.1 v2.1.3" "v2.1.1=$BASELINE" > /dev/null 2>&1 \
  || fail "mapped version: resolve_fork_baselines failed"
grep -qx 'probe txehq/bifrost v2.1.3' "$CALLS" || fail "mapped version: an explicit mapping was probed again ($(grep probe "$CALLS"))"

if FAKE_GHCR_FAIL=1 resolve "v2.1.3" "" > /dev/null 2>&1; then
  fail "probe failure: resolve_fork_baselines succeeded"
fi
grep -q '^docker create' "$CALLS" && fail "probe failure: an image was pulled"

if FAKE_GHCR_STATES='v1.5.11 absent\n' resolve "v1.5.11 v2.1.3" "" > /dev/null 2>&1; then
  fail "missing state: a version the probe did not classify was accepted"
fi

if FAKE_GHCR_STATES='v2.1.3 present\n' FAKE_DOCKER_CREATE_FAIL=1 resolve "v2.1.3" "" > /dev/null 2>&1; then
  fail "pull failure: resolve_fork_baselines succeeded without the fork binary"
fi

# A failed copy or removal fails the run and leaves the container for the exit trap:
# FORK_BASELINE_CID still names it.
left_for_cleanup() {
  : > "$CALLS"
  env TMPDIR="$RESOLVE_TMP" PATH="$FORK_DOCKER_BIN:$PATH" MIGRATION_TEST_VERSIONS="v2.1.3" MIGRATION_LOCAL_BINARIES="" \
    MIGRATION_FORK_IMAGES=txehq/bifrost GITHUB_TOKEN=fake-token-value FAKE_GHCR_STATES='v2.1.3 present\n' \
    "$@" bash -c "
    set -uo pipefail
    log_info() { :; }
    log_error() { :; }
    SCRIPT_DIR='$FAKE_SCRIPTS' REPO_ROOT='$REPO_ROOT' VERSIONS_TO_TEST=3 FORK_BASELINE_DIR='' FORK_BASELINE_CID=''
    $resolve_functions
    resolve_fork_baselines && exit 1
    echo \"\$FORK_BASELINE_CID\"
  "
}
for failing in FAKE_DOCKER_CP_FAIL FAKE_DOCKER_RM_FAIL; do
  cid_left="$(left_for_cleanup "$failing=1")" || fail "$failing: resolve_fork_baselines succeeded"
  [ "$cid_left" = "cid-v2.1.3" ] || fail "$failing: the extraction container was not left for cleanup (got '$cid_left')"
done

[ -n "$(ls -A "$RESOLVE_TMP")" ] || fail "resolver allocations did not land under \$WORK, so they outlive this test"

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "OK: invalid MIGRATION_LOCAL_BINARIES mappings fail closed; valid and absent mappings start the right baseline; fork images resolve only on a definite registry answer."
