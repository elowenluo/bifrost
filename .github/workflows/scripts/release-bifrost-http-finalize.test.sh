#!/usr/bin/env bash
set -uo pipefail

# Runs the real release-bifrost-http-finalize.sh end to end against a scratch origin.
#
# The fork's pipeline first reached this script on 2026-10-22 and it died on its first
# line: the job had no Go 1.27 and could not fetch one (TXE-4977). This test runs it on a
# single-commit snapshot of the checkout, pushed to a bare repository that stands in for
# origin, with a gh shim that records the release it is asked to create. Nothing leaves
# the machine. It needs the Go that go.work requires on PATH, as the job does.
#
# Usage: ./release-bifrost-http-finalize.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/src"

FAILURES=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILURES=$((FAILURES + 1)); }

GIT_ID=(-c user.name=test -c user.email=test@example.invalid)

# The snapshot carries the working tree as committed, with an older transports tag on
# origin whose message differs from the current changelog.
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$WORK/src"
git -C "$WORK/src" init -q -b main
git -C "$WORK/src" add -A
git -C "$WORK/src" "${GIT_ID[@]}" commit -q -m snapshot
git -C "$WORK/src" "${GIT_ID[@]}" tag -a transports/v0.0.1 -m "Release transports v0.0.1" -m "- an older release"
git init -q --bare -b main "$WORK/origin.git"
git -C "$WORK/src" push -q "$WORK/origin.git" main 'refs/tags/*'
git clone -q "$WORK/origin.git" "$WORK/clone"
git -C "$WORK/clone" config user.name test
git -C "$WORK/clone" config user.email test@example.invalid

cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/gh-args"
EOF
chmod +x "$WORK/bin/gh"

VERSION="$(tr -d '\n\r' < "$REPO_ROOT/transports/version")"
: > "$WORK/output"
(cd "$WORK/clone" && PATH="$WORK/bin:$PATH" GH_TOKEN=fixture GITHUB_REPOSITORY=txehq/bifrost \
  GITHUB_REPOSITORY_OWNER=txehq GITHUB_OUTPUT="$WORK/output" R2_ENDPOINT='' R2_BUCKET='' \
  bash ./.github/workflows/scripts/release-bifrost-http-finalize.sh "$VERSION") > "$WORK/log" 2>&1
RC=$?

if [ "$RC" -eq 0 ]; then pass "finalize succeeds"; else fail "finalize failed (rc=$RC): $(tail -5 "$WORK/log")"; fi

tag_commit="$(git -C "$WORK/origin.git" rev-parse -q --verify "refs/tags/transports/v$VERSION^{commit}")"
main_commit="$(git -C "$WORK/origin.git" rev-parse main)"
if [ -n "$tag_commit" ] && [ "$tag_commit" = "$main_commit" ]; then
  pass "transports/v$VERSION is pushed at the checked-out commit"
else
  fail "transports/v$VERSION is missing or not at main ($tag_commit vs $main_commit)"
fi

if [ "$(sed -n 1,3p "$WORK/gh-args" 2>/dev/null | tr '\n' ' ')" = "release create transports/v$VERSION " ]; then
  pass "gh creates the release for the tag"
else
  fail "unexpected gh call: $(head -3 "$WORK/gh-args" 2>/dev/null | tr '\n' ' ')"
fi

if grep -q -- "Bifrost HTTP v$VERSION" "$WORK/gh-args"; then pass "release is titled for v$VERSION"; else fail "release title missing"; fi

if grep -qx 'success=true' "$WORK/output"; then pass "step output reports success"; else fail "no success=true in step output"; fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
