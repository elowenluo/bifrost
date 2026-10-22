#!/usr/bin/env bash
set -uo pipefail

# Tests the MIGRATION_LOCAL_BINARIES override in run-migration-tests.sh.
#
# The override exists so a migration run can start from the deployed fork build instead of
# upstream's npx release. An explicit mapping that cannot run (an empty path from an unset
# variable, a typo, a file without the executable bit) must fail the run: falling back to
# npx would migrate from upstream's build and still report success for the fork build.
#
# The invalid-mapping scenarios run the real script end to end with fake git, npx and
# docker first on PATH, so nothing leaves the machine; the script must stop before any of
# them is asked to start a baseline. The launch scenarios run the script's own
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
  output="$(cd "$REPO_ROOT" && PATH="$FAKE_BIN:$PATH" MIGRATION_TEST_VERSIONS="v2.1.1" \
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

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "OK: invalid MIGRATION_LOCAL_BINARIES mappings fail closed; valid and absent mappings start the right baseline."
