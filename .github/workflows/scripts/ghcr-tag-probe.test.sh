#!/usr/bin/env bash
set -uo pipefail

# Tests the GHCR tag probe in detect-all-changes.sh.
#
# That probe decides docker-needs-release, which is what starts the release pipeline's image
# publishing jobs. Pushing a tag that already exists overwrites a published image with a
# rebuild, so "absent" has to be a definite answer from the registry, never the leftover
# when a lookup fails - and it has to be decided per tag, because a failed run can leave
# some of a release's six tags published and the rest not. Each publishing job then checks
# its own tag again before pushing; test-docker-publish-gates.py covers that.
# ghcr.io/txehq/bifrost is private: an anonymous token request for it is refused with 401,
# which is exactly the failure an unauthenticated probe used to read as "absent".
#
# This runs the real script end to end, with a fake curl (testdata/fake-ghcr-curl) and a
# no-op sleep first on PATH, so no request leaves the machine and no credential is real.
# Each scenario scripts the registry's answers and checks what the script reports.
#
# Usage: ./ghcr-tag-probe.test.sh
#        DETECT_ALL_CHANGES=/path/to/other/detect-all-changes.sh ./ghcr-tag-probe.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${DETECT_ALL_CHANGES:-${SCRIPT_DIR}/detect-all-changes.sh}"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is required" >&2
    exit 1
  fi
done

V="v$(cat "$REPO_ROOT/transports/version")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"

# Sentinels: a scenario fails if either appears in the script's output or in any curl argv,
# where a process listing would expose it.
JOB_TOKEN="ghs_SENTINELjobtoken0123456789"
BEARER="SENTINELbearer456+/="

# The fake registry (see testdata/fake-ghcr-curl for its response format).
cp "$SCRIPT_DIR/testdata/fake-ghcr-curl" "$FAKE_BIN/curl"
cat > "$FAKE_BIN/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_DIR/sleep.log"
FAKE
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/sleep"

TOKEN_OK="200 0 {\"token\":\"${BEARER}\"}"
MANIFEST_OK='200 0 {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
MANIFEST_UNKNOWN='404 0 {"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'
TAGS_OK='200 0 {"name":"txehq/bifrost","tags":["v2.1.1","latest"]}'

# Every destination a release publishes: short name, tag.
DESTINATIONS=(
  "version $V"
  "amd64 $V-amd64"
  "arm64 $V-arm64"
  "ubi9 $V-ubi9"
  "ubi9-amd64 $V-ubi9-amd64"
  "ubi9-arm64 $V-ubi9-arm64"
)

passed=0
failed=0
SCENARIO=""
FAKE_DIR=""
RC=0

# new_scenario <name>: a fresh response directory.
new_scenario() {
  SCENARIO="$1"
  FAKE_DIR="$WORK/scenarios/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
  mkdir -p "$FAKE_DIR"
  : > "$FAKE_DIR/calls.log"
  : > "$FAKE_DIR/argv.log"
  : > "$FAKE_DIR/stdin.log"
  : > "$FAKE_DIR/github_output"
}

# respond <key> <line>...: queue registry answers for one endpoint (or one manifest tag).
respond() {
  local key="$1"
  shift
  printf '%s\n' "$@" >> "$FAKE_DIR/$key"
}

# run_detect [env assignments...]: run the real script against the fake registry.
run_detect() {
  (
    cd "$REPO_ROOT" || exit 98
    env -u GITHUB_TOKEN -u GITHUB_ACTIONS \
      PATH="$FAKE_BIN:$PATH" \
      FAKE_DIR="$FAKE_DIR" \
      GITHUB_OUTPUT="$FAKE_DIR/github_output" \
      GITHUB_REPOSITORY_OWNER=txehq \
      "$@" \
      bash "$TARGET"
  ) > "$FAKE_DIR/log" 2>&1
  RC=$?
}

ok() {
  echo "  ok - $SCENARIO: $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL: $SCENARIO: $1" >&2
  failed=$((failed + 1))
}

calls() {
  grep -c "^$1 " "$FAKE_DIR/calls.log" || true
}

check_no_leak() {
  if grep -qF -e "$JOB_TOKEN" -e "$BEARER" "$FAKE_DIR/log"; then
    fail "a credential was printed to the job log"
  elif grep -qF -e "$JOB_TOKEN" -e "$BEARER" "$FAKE_DIR/argv.log"; then
    fail "a credential was passed on curl's command line"
  else
    ok "no credential in log or argv"
  fi
}

# expect_release <docker-needs-release> <short names of the destinations seen absent...>:
# the run succeeded and reported exactly those destinations absent and the rest published.
expect_release() {
  local want="$1"
  shift
  local absent=" $* " entry name tag line
  if [ "$RC" -ne 0 ]; then
    fail "script exited $RC, expected docker-needs-release=$want (log: $(tail -3 "$FAKE_DIR/log" | tr '\n' ' '))"
    check_no_leak
    return
  fi
  if grep -qx "docker-needs-release=$want" "$FAKE_DIR/github_output"; then
    ok "docker-needs-release=$want"
  else
    fail "expected docker-needs-release=$want, got: $(grep docker-needs-release "$FAKE_DIR/github_output" || echo none)"
  fi
  for entry in "${DESTINATIONS[@]}"; do
    name="${entry%% *}"
    tag="${entry#* }"
    line="Docker tag ${tag} already exists on GHCR"
    [[ "$absent" == *" $name "* ]] && line="Docker tag ${tag} confirmed absent on GHCR"
    if grep -qF "$line" "$FAKE_DIR/log"; then
      ok "$line"
    else
      fail "expected '$line'"
    fi
  done
  check_no_leak
}

# The registry's answer was not definitive: the job must fail, publish nothing, and say why.
expect_fail_closed() {
  local reason="$1"
  if grep -qx "docker-needs-release=true" "$FAKE_DIR/github_output"; then
    fail "emitted docker-needs-release=true on an ambiguous registry answer"
  elif [ "$RC" -eq 0 ]; then
    fail "script exited 0 on an ambiguous registry answer"
  elif [ -s "$FAKE_DIR/github_output" ]; then
    fail "wrote GITHUB_OUTPUT on an ambiguous registry answer"
  elif ! grep -q "::error::.*${reason}" "$FAKE_DIR/log"; then
    fail "exited $RC without an ::error:: naming '${reason}' (log: $(grep '::error::' "$FAKE_DIR/log" | tr '\n' ' '))"
  else
    ok "failed closed (${reason})"
  fi
  check_no_leak
}

expect_calls() {
  local kind="$1" want="$2" got
  got=$(calls "$kind")
  if [ "$got" -eq "$want" ]; then
    ok "$kind requested $want time(s)"
  else
    fail "$kind requested $got time(s), expected $want"
  fi
}

# The probe must authenticate with the job token, through curl's stdin config.
expect_authenticated() {
  if grep -qF "$JOB_TOKEN" "$FAKE_DIR/stdin.log" && grep -qF "Bearer $BEARER" "$FAKE_DIR/stdin.log"; then
    ok "token exchange and lookups were authenticated"
  else
    fail "the registry lookups were not authenticated with the job token"
  fi
  if grep -q "scope=repository:txehq/bifrost:pull" "$FAKE_DIR/calls.log"; then
    ok "token scoped to txehq/bifrost pull"
  else
    fail "token request was not scoped to repository:txehq/bifrost:pull"
  fi
}

# Every destination must have been looked up, each by its own tag.
expect_every_destination_checked() {
  local entry tag missing=""
  for entry in "${DESTINATIONS[@]}"; do
    tag="${entry#* }"
    grep -q "/manifests/${tag}\$" "$FAKE_DIR/calls.log" || missing+=" $tag"
  done
  if [ -z "$missing" ]; then
    ok "all six destinations looked up"
  else
    fail "destinations never looked up:$missing"
  fi
}

echo "GHCR tag probe ($TARGET, $V)"

# --- Definitive answers ----------------------------------------------------------------

new_scenario "every destination published"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release false
expect_authenticated
expect_every_destination_checked
expect_calls tags 0

new_scenario "nothing published yet"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release true version amd64 arm64 ubi9 ubi9-amd64 ubi9-arm64
expect_authenticated
expect_every_destination_checked
expect_calls tags 1

new_scenario "transient 503 then every destination published"
respond token "$TOKEN_OK"
respond manifest '503 0 {"errors":[{"code":"UNAVAILABLE"}]}' "$MANIFEST_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release false
expect_calls manifest 7

# --- Partial releases: each destination is reported on its own -----------------------------

new_scenario "architecture images published, manifests and UBI9 not"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond "manifest:$V-amd64" "$MANIFEST_OK"
respond "manifest:$V-arm64" "$MANIFEST_OK"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release true version ubi9 ubi9-amd64 ubi9-arm64

new_scenario "everything but the UBI9 manifest published"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_OK"
respond "manifest:$V-ubi9" "$MANIFEST_UNKNOWN"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release true ubi9

new_scenario "only amd64 published"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond "manifest:$V-amd64" "$MANIFEST_OK"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release true version arm64 ubi9 ubi9-amd64 ubi9-arm64

new_scenario "one destination ambiguous among published ones"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_OK"
respond "manifest:$V-ubi9-arm64" '500 0 {"errors":[{"code":"UNKNOWN"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "500"

# --- Credentials -------------------------------------------------------------------------

new_scenario "no job token"
run_detect
expect_fail_closed "GITHUB_TOKEN"
expect_calls token 0

new_scenario "token exchange 401"
respond token '401 0 {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "401"
expect_calls token 1
expect_calls manifest 0

new_scenario "token exchange 403"
respond token '403 0 {"errors":[{"code":"DENIED","message":"denied"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "403"
expect_calls token 1

new_scenario "token exchange returns no token"
respond token '200 0 {"errors":[]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

new_scenario "token exchange returns a malformed token"
respond token '200 0 {"token":"abc\"def ghi"}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

new_scenario "token exchange body has trailing bytes"
respond token "200 0 {\"token\":\"${BEARER}\"} junk"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

# The token is judged on the exact JSON string. Each of these, once printed into a shell
# variable, loses the offending character - a trailing newline is stripped, a NUL dropped -
# and would come out looking like a valid token.
for bad in '\n' '\u0000' '\t' '\u0001' '\r'; do
  new_scenario "token with ${bad} appended"
  respond token "200 0 {\"token\":\"${BEARER}${bad}\"}"
  respond manifest "$MANIFEST_UNKNOWN"
  respond tags "$TAGS_OK"
  run_detect GITHUB_TOKEN="$JOB_TOKEN"
  expect_fail_closed "no usable token"
  expect_calls manifest 0
done

new_scenario "token with an embedded NUL"
respond token "200 0 {\"token\":\"SENTINEL\\u0000bearer\"}"
respond manifest "$MANIFEST_UNKNOWN"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

new_scenario "token with a leading newline"
respond token "200 0 {\"token\":\"\\n${BEARER}\"}"
respond manifest "$MANIFEST_UNKNOWN"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

new_scenario "empty token"
respond token '200 0 {"token":""}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "no usable token"
expect_calls manifest 0

new_scenario "token given as access_token"
respond token "200 0 {\"access_token\":\"${BEARER}\"}"
respond manifest "$MANIFEST_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_release false
expect_authenticated

new_scenario "token exchange network failure"
respond token '000 7'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "network"
expect_calls token 3

# --- Ambiguous manifest answers ----------------------------------------------------------

new_scenario "manifest 401"
respond token "$TOKEN_OK"
respond manifest '401 0 {"errors":[{"code":"UNAUTHORIZED"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "401"
expect_calls manifest 1

new_scenario "manifest 403"
respond token "$TOKEN_OK"
respond manifest '403 0 {"errors":[{"code":"DENIED"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "403"
expect_calls manifest 1

new_scenario "manifest 429 throughout"
respond token "$TOKEN_OK"
respond manifest '429 0 {"errors":[{"code":"TOOMANYREQUESTS"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "429"
expect_calls manifest 3

new_scenario "manifest 500 throughout"
respond token "$TOKEN_OK"
respond manifest '500 0 {"errors":[{"code":"UNKNOWN"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "500"
expect_calls manifest 3

new_scenario "manifest network failure"
respond token "$TOKEN_OK"
respond manifest '000 28'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "network"
expect_calls manifest 3

new_scenario "manifest 404 without a registry error"
respond token "$TOKEN_OK"
respond manifest '404 0 <html>Not Found</html>'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "404"
expect_calls tags 0

new_scenario "manifest 404 NAME_UNKNOWN"
respond token "$TOKEN_OK"
respond manifest '404 0 {"errors":[{"code":"NAME_UNKNOWN"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "NAME_UNKNOWN"

# Exactness: each of these yields the safe answer only after something lossy - a parser that
# printed before it failed, or characters deleted - so each must be refused.
new_scenario "manifest 404 MANIFEST_UNKNOWN followed by trailing bytes"
respond token "$TOKEN_OK"
respond manifest '404 0 {"errors":[{"code":"MANIFEST_UNKNOWN"}]} invalid'
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "404"
expect_calls tags 0

new_scenario "manifest 404 as two JSON documents"
respond token "$TOKEN_OK"
respond manifest '404 0 {"errors":[{"code":"MANIFEST_UNKNOWN"}]} {"errors":[]}'
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "404"

new_scenario "manifest 404 MANIFEST_UNKNOWN123"
respond token "$TOKEN_OK"
respond manifest '404 0 {"errors":[{"code":"MANIFEST_UNKNOWN123"}]}'
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "404"

new_scenario "manifest 404 code with a space"
respond token "$TOKEN_OK"
respond manifest '404 0 {"errors":[{"code":"MANIFEST_UNKNOWN "}]}'
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "404"

new_scenario "manifest 200 without a manifest body"
respond token "$TOKEN_OK"
respond manifest '200 0 <html>Sign in</html>'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "without a manifest body"

new_scenario "manifest 200 with trailing bytes"
respond token "$TOKEN_OK"
respond manifest '200 0 {"schemaVersion":2} <html>'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "without a manifest body"

new_scenario "manifest redirect"
respond token "$TOKEN_OK"
respond manifest '307 0 '
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "307"

# --- Absence must be proven against a repository the token can see ---------------------

# Measured against ghcr.io: a valid token gets 404 MANIFEST_UNKNOWN for a repository that
# does not exist, so a manifest 404 alone cannot tell "tag absent" from "cannot see it".
new_scenario "manifest absent but repository not visible"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '404 0 {"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "not visible"

new_scenario "manifest absent but tag listing 403"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '403 0 {"errors":[{"code":"DENIED"}]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "403"

new_scenario "manifest absent but tag listing names another repository"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '200 0 {"name":"someone/else","tags":[]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "tag listing"

new_scenario "manifest absent but tag listing name differs by one character"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '200 0 {"name":"txehq/bifrost!","tags":[]}'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "tag listing"

new_scenario "manifest absent but tag listing has trailing bytes"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '200 0 {"name":"txehq/bifrost","tags":[]} junk'
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "tag listing"

new_scenario "manifest absent but tag listing 502 throughout"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags '502 0 '
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_fail_closed "502"
expect_calls tags 3

echo ""
if [ "$failed" -ne 0 ]; then
  echo "$failed failed, $passed passed" >&2
  exit 1
fi
echo "$passed passed"
