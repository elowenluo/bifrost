#!/usr/bin/env bash
set -uo pipefail

# Tests the GHCR tag probe in detect-all-changes.sh.
#
# That probe decides docker-needs-release, and docker-needs-release=true is what lets the
# release pipeline push v<transport-version> to ghcr.io. Pushing a tag that already exists
# overwrites a published image with a rebuild, so "absent" has to be a definite answer from
# the registry, never the leftover when a lookup fails. ghcr.io/txehq/bifrost is private: an
# anonymous token request for it is refused with 401, which is exactly the failure an
# unauthenticated probe used to read as "absent".
#
# This runs the real script end to end, with a fake curl (and a no-op sleep) first on PATH,
# so no request leaves the machine and no credential is real. Each scenario scripts the
# registry's answers and checks what the script emits to GITHUB_OUTPUT.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"

# Sentinels: a scenario fails if either appears in the script's output or in any curl argv,
# where a process listing would expose it.
JOB_TOKEN="ghs_SENTINELjobtoken0123456789"
BEARER="SENTINELbearer456+/="

# The fake curl. Responses for each endpoint come from $FAKE_DIR/<kind>, one line per
# request, "<http status> <curl exit code> <body>"; the last line repeats once exhausted.
cat > "$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
out="" fmt="" url="" fail=0
printf '%s\n' "$*" >> "$FAKE_DIR/argv.log"
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -w|--write-out) fmt="$2"; shift 2 ;;
    -K|--config)
      if [ "$2" = "-" ]; then cat >> "$FAKE_DIR/stdin.log"; fi
      shift 2 ;;
    -H|--header|--connect-timeout|--max-time|-u|--user) shift 2 ;;
    --fail) fail=1; shift ;;
    --*) shift ;;
    -*) case "$1" in *f*) fail=1 ;; esac; shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  "https://ghcr.io/token?"*) kind=token ;;
  "https://ghcr.io/v2/"*"/manifests/"*) kind=manifest ;;
  "https://ghcr.io/v2/"*"/tags/list"*) kind=tags ;;
  *) echo "fake curl: unexpected URL: $url" >&2; exit 99 ;;
esac
echo "$kind $url" >> "$FAKE_DIR/calls.log"
n=$(( $(cat "$FAKE_DIR/$kind.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/$kind.n"
total=$(wc -l < "$FAKE_DIR/$kind")
[ "$n" -gt "$total" ] && n="$total"
read -r status code body < <(sed -n "${n}p" "$FAKE_DIR/$kind")
if [ "$code" != "0" ]; then
  [ -n "$fmt" ] && printf '000'
  echo "curl: ($code) Failed to connect to ghcr.io" >&2
  exit "$code"
fi
if [ "$fail" = "1" ] && [ "$status" -ge 400 ]; then
  [ -n "$fmt" ] && printf '%s' "$status"
  echo "curl: (22) The requested URL returned error: $status" >&2
  exit 22
fi
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ -n "$fmt" ] && printf '%s' "$status"
exit 0
FAKE
cat > "$FAKE_BIN/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_DIR/sleep.log"
FAKE
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/sleep"

TOKEN_OK="200 0 {\"token\":\"${BEARER}\"}"
MANIFEST_OK='200 0 {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
MANIFEST_UNKNOWN='404 0 {"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'
TAGS_OK='200 0 {"name":"txehq/bifrost","tags":["v2.1.1","latest"]}'

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

# respond <kind> <line>...: queue registry answers for one endpoint.
respond() {
  local kind="$1"
  shift
  printf '%s\n' "$@" >> "$FAKE_DIR/$kind"
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

expect_docker_release() {
  local want="$1"
  if [ "$RC" -ne 0 ]; then
    fail "script exited $RC, expected docker-needs-release=$want (log: $(tail -3 "$FAKE_DIR/log" | tr '\n' ' '))"
  elif ! grep -qx "docker-needs-release=$want" "$FAKE_DIR/github_output"; then
    fail "expected docker-needs-release=$want, got: $(grep docker-needs-release "$FAKE_DIR/github_output" || echo none)"
  else
    ok "docker-needs-release=$want"
  fi
  check_no_leak
}

# The registry's answer was not definitive: the job must fail, publish nothing, and say why.
expect_fail_closed() {
  local reason="$1"
  if grep -qx "docker-needs-release=true" "$FAKE_DIR/github_output"; then
    fail "emitted docker-needs-release=true on an ambiguous registry answer"
  elif [ "$RC" -eq 0 ]; then
    fail "script exited 0 on an ambiguous registry answer"
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

echo "GHCR tag probe ($TARGET)"

# --- Definitive answers ----------------------------------------------------------------

new_scenario "existing tag"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_docker_release false
expect_authenticated
expect_calls tags 0

new_scenario "absent tag in a visible repository"
respond token "$TOKEN_OK"
respond manifest "$MANIFEST_UNKNOWN"
respond tags "$TAGS_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_docker_release true
expect_authenticated
expect_calls tags 1

new_scenario "transient 503 then existing tag"
respond token "$TOKEN_OK"
respond manifest '503 0 {"errors":[{"code":"UNAVAILABLE"}]}' "$MANIFEST_OK"
run_detect GITHUB_TOKEN="$JOB_TOKEN"
expect_docker_release false
expect_calls manifest 2

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

new_scenario "manifest 200 without a manifest body"
respond token "$TOKEN_OK"
respond manifest '200 0 <html>Sign in</html>'
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
