#!/usr/bin/env bash

# Shared by the release scripts that leave generated changes as a patch instead of
# pushing them: main requires a reviewed codex-review check, so a generated change
# reaches main only through a reviewed PR that applies the patch.
# Usage: source .github/workflows/scripts/release-patch-utils.sh

# Fails unless the checkout is the commit this workflow run tested, so a patch, and
# anything built next to it, describes exactly that commit.
assert_tested_checkout() {
  local head
  head="$(git rev-parse HEAD)"
  if [ -n "${GITHUB_SHA:-}" ] && [ "$head" != "$GITHUB_SHA" ]; then
    echo "::error::checkout is $head, but this run tested $GITHUB_SHA" >&2
    return 1
  fi
}

# Prints the directory patches are written to, creating it: RELEASE_PATCH_DIR, or
# $RUNNER_TEMP/release-patches. It has to be outside the checkout, so no later
# `git add` or build in the job can pick a patch up.
release_patch_dir() {
  local dir="${RELEASE_PATCH_DIR:-}" top
  if [ -z "$dir" ]; then
    if [ -z "${RUNNER_TEMP:-}" ]; then
      echo "::error::set RELEASE_PATCH_DIR or RUNNER_TEMP to a directory outside the checkout" >&2
      return 1
    fi
    dir="$RUNNER_TEMP/release-patches"
  fi
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd -P)"
  top="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
  case "$dir/" in
    "$top"/*)
      echo "::error::patch directory $dir is inside the checkout $top" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$dir"
}

# One patch per (kind, version, commit): <kind>-v<version>-<commit[:12]>.patch.
# Usage: release_patch_name <kind> <version>
release_patch_name() {
  printf '%s-v%s-%s.patch\n' "$1" "$2" "$(git rev-parse --short=12 HEAD)"
}

# Fails unless the patch applies to the tested commit and touches only the listed paths.
# Usage: assert_patch_allowlist <patch> <path>...
assert_patch_allowlist() {
  local patch="$1" path allowed ok
  shift
  if ! git apply --check --cached "$patch"; then
    echo "::error::$(basename "$patch") does not apply to $(git rev-parse HEAD)" >&2
    return 1
  fi
  while IFS=$'\t' read -r _ _ path; do
    ok=false
    for allowed in "$@"; do
      if [ "$path" = "$allowed" ]; then
        ok=true
      fi
    done
    if [ "$ok" != true ]; then
      echo "::error::$(basename "$patch") touches $path, which is outside its allowlist" >&2
      return 1
    fi
  done < <(git apply --numstat "$patch")
}

# Writes every change in the checkout as one patch against HEAD and sets RELEASE_PATCH
# to its path. Each changed path, tracked or not, must be on the allowlist. A private
# index stages the patch, so the checkout's own index and refs are never touched.
# Usage: write_release_patch <kind> <version> <path>...
write_release_patch() {
  local kind="$1" version="$2" dir work path allowed ok
  local -a changed=()
  shift 2
  while IFS= read -r path; do
    ok=false
    for allowed in "$@"; do
      if [ "$path" = "$allowed" ]; then
        ok=true
      fi
    done
    if [ "$ok" != true ]; then
      echo "::error::$path changed, and is outside the $kind allowlist" >&2
      return 1
    fi
    changed+=("$path")
  done < <(git status --porcelain=v1 --untracked-files=all | cut -c4-)
  if [ "${#changed[@]}" -eq 0 ]; then
    echo "::error::no $kind changes were generated" >&2
    return 1
  fi

  dir="$(release_patch_dir)"
  RELEASE_PATCH="$dir/$(release_patch_name "$kind" "$version")"
  work="$(mktemp -d)"
  GIT_INDEX_FILE="$work/index" git read-tree HEAD
  GIT_INDEX_FILE="$work/index" git add -- "${changed[@]}"
  GIT_INDEX_FILE="$work/index" git diff --cached --binary --no-color --no-ext-diff \
    --src-prefix=a/ --dst-prefix=b/ HEAD > "$RELEASE_PATCH"
  rm -rf "$work"
  assert_patch_allowlist "$RELEASE_PATCH" "$@"
}

# Prints the lines, and appends them to the job summary when there is one.
release_summary() {
  printf '%s\n' "$@"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}
