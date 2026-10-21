#!/usr/bin/env bash
# Authenticated, fail-closed lookups of image tags on ghcr.io. Sourced, not executed: by
# detect-all-changes.sh, which decides whether a release has anything to publish, and by
# ghcr-tag-gate.sh, which every publishing job runs again right before it pushes.
#
# Pushing a tag that already exists replaces a published image with a rebuild, so "absent"
# has to be a definite answer from the registry, never what is left over when a lookup
# fails. ghcr.io/txehq/bifrost is private: an anonymous token request for it is refused
# with 401, which an unauthenticated probe used to read as "absent" on every run (release
# run 34764966937 rebuilt and re-pushed all of v2.1.1).
#
# Measured against ghcr.io (2026-10-22, TXE-4819) with an authorized token: an existing
# tag answers 200 and a missing one 404 MANIFEST_UNKNOWN - but so does any tag in a
# repository that does not exist or that the token cannot see. tags/list tells those
# apart (200 for a visible repository, 404 NAME_UNKNOWN otherwise). So a tag is absent
# only when its manifest answers 404 MANIFEST_UNKNOWN and the repository's tag listing
# answers 200 under the same token. Any other outcome is a failure, never a guess.
#
# Requires curl, jq and GITHUB_TOKEN (a token that can read the package).
GHCR_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
GHCR_ATTEMPTS=3

# ghcr_request <label> <curl config> <body file> <url> [curl args...]
# Credentials travel in the curl config on stdin, so they never reach curl's argv (and
# with it any process listing). Sets GHCR_STATUS to the HTTP status, or 000 when curl did
# not complete. 000, 429 and 5xx are retried, at most GHCR_ATTEMPTS times in all.
ghcr_request() {
  local label="$1" config="$2" body_file="$3" url="$4" attempt=1
  shift 4
  while :; do
    GHCR_STATUS=$(printf '%s\n' "$config" | curl -sS --config - \
      --connect-timeout 10 --max-time 30 \
      -o "$body_file" -w '%{http_code}' "$@" "$url") || GHCR_STATUS="000"
    case "$GHCR_STATUS" in
      000|429|5[0-9][0-9]) ;;
      *) return 0 ;;
    esac
    if [ "$attempt" -ge "$GHCR_ATTEMPTS" ]; then
      return 0
    fi
    echo "   ⚠️ GHCR ${label} answered HTTP ${GHCR_STATUS}, retrying (${attempt}/${GHCR_ATTEMPTS})" >&2
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
}

# ghcr_json_is <file> <jq condition> [jq args...]: succeeds only when the file holds exactly
# one JSON document and the condition is true of it. Safety decisions compare the raw
# values inside jq; nothing is cleaned up in the shell first, and a parse failure anywhere
# in the body - trailing bytes, a second document - is a failure, not a partial answer.
ghcr_json_is() {
  local file="$1" condition="$2"
  shift 2
  jq -e -s "$@" "length == 1 and (.[0] | (${condition}))" "$file" >/dev/null 2>&1
}

# ghcr_json_string <file> <jq path>: prints the string at the path when the file holds
# exactly one JSON document and the value there is a string; fails otherwise.
ghcr_json_string() {
  jq -e -r -s "if length == 1 and (.[0] | ${2} | type) == \"string\" then .[0] | ${2} else error(\"no\") end" "$1" 2>/dev/null
}

# For log messages only: a registry error code reduced to [A-Z_], never used in a decision.
ghcr_error_code_for_log() {
  { ghcr_json_string "$1" '.errors[0].code' || true; } | tr -cd 'A-Z_' | cut -c1-40
}

# ghcr_fail <what> <body file>: explain an answer that is not definitive. The response
# body is never printed - only its registry error code - so nothing secret reaches the log.
ghcr_fail() {
  local what="$1" code
  code=$(ghcr_error_code_for_log "$2")
  local detail="HTTP ${GHCR_STATUS}${code:+ ${code}}"
  case "$GHCR_STATUS" in
    000)
      echo "::error::GHCR ${what}: network error, no HTTP response after ${GHCR_ATTEMPTS} attempts. The tag's state is unknown; re-run once ghcr.io is reachable." >&2 ;;
    401|403)
      echo "::error::GHCR ${what}: ${detail}, the job token was refused. Check that the detect-changes job grants 'packages: read' and that the package grants this repository read access (package settings, Manage Actions access)." >&2 ;;
    429)
      echo "::error::GHCR ${what}: ${detail}, rate limited after ${GHCR_ATTEMPTS} attempts. The tag's state is unknown; re-run later." >&2 ;;
    5[0-9][0-9])
      echo "::error::GHCR ${what}: ${detail}, registry error after ${GHCR_ATTEMPTS} attempts. The tag's state is unknown; re-run later." >&2 ;;
    *)
      echo "::error::GHCR ${what}: unexpected response (${detail}); refusing to read it as tag absence." >&2 ;;
  esac
  return 1
}

# ghcr_tag_states <owner/name> <tag>...: prints "<tag> present" or "<tag> absent" for every
# tag and returns 0 only when the registry answered each one definitively; otherwise
# explains on stderr and returns 1. The body runs in a subshell so its temporary
# directory is removed however it returns.
ghcr_tag_states() (
  repository="$1"
  shift
  if [[ ! "$repository" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "::error::refusing malformed GHCR repository name: '${repository}'" >&2
    return 1
  fi
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "::error::GITHUB_TOKEN is not set, so ghcr.io/${repository} cannot be queried and the state of its tags is unknown. The release pipeline passes the job token; for a local run, export a token with read:packages as GITHUB_TOKEN." >&2
    return 1
  fi
  # A GitHub token is [A-Za-z0-9_]; anything else could break out of the curl config line.
  if [[ ! "$GITHUB_TOKEN" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "::error::GITHUB_TOKEN contains characters a GitHub token never has; refusing to use it." >&2
    return 1
  fi

  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT

  ghcr_request "token exchange" "user = \"token:${GITHUB_TOKEN}\"" "$tmp/token" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull"
  if [ "$GHCR_STATUS" != "200" ]; then
    ghcr_fail "token exchange for ${repository}" "$tmp/token"
    return 1
  fi
  # RFC 6750 b64token, which also keeps the value inert inside the quoted config line. It is
  # checked inside jq, on the exact JSON string: once jq -r prints it into a command
  # substitution, a trailing newline is stripped and a NUL dropped, so a malformed token
  # would come out looking valid. gsub rather than an anchored test(), whose $ also matches
  # before a trailing newline.
  bearer=$(jq -e -r -s '
      (if length == 1 then .[0] | (.token // .access_token) else null end)
      | if type == "string" and length > 0 and gsub("[A-Za-z0-9._~+/=-]"; "") == ""
        then . else error("no usable token") end
    ' "$tmp/token" 2>/dev/null) || bearer=""
  if [[ ! "$bearer" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "::error::GHCR token exchange for ${repository} answered HTTP 200 with no usable token." >&2
    return 1
  fi
  auth="header = \"Authorization: Bearer ${bearer}\""

  states=""
  any_absent="false"
  for tag in "$@"; do
    ghcr_request "manifest lookup" "$auth" "$tmp/manifest" \
      "https://ghcr.io/v2/${repository}/manifests/${tag}" -H "Accept: ${GHCR_ACCEPT}"
    case "$GHCR_STATUS" in
      200)
        if ! ghcr_json_is "$tmp/manifest" '.schemaVersion == 2'; then
          echo "::error::GHCR manifest lookup for ${repository}:${tag} answered HTTP 200 without a manifest body; refusing to guess the tag's state." >&2
          return 1
        fi
        states+="${tag} present"$'\n' ;;
      404)
        if ! ghcr_json_is "$tmp/manifest" '.errors[0].code == "MANIFEST_UNKNOWN"'; then
          ghcr_fail "manifest lookup for ${repository}:${tag}" "$tmp/manifest"
          return 1
        fi
        states+="${tag} absent"$'\n'
        any_absent="true" ;;
      *)
        ghcr_fail "manifest lookup for ${repository}:${tag}" "$tmp/manifest"
        return 1 ;;
    esac
  done

  if [ "$any_absent" = "true" ]; then
    ghcr_request "tag listing" "$auth" "$tmp/tags" "https://ghcr.io/v2/${repository}/tags/list?n=1"
    case "$GHCR_STATUS" in
      200)
        if ! ghcr_json_is "$tmp/tags" '.name == $repo' --arg repo "$repository"; then
          echo "::error::GHCR tag listing for ${repository} answered HTTP 200 for a different or malformed repository name; refusing to read the manifest 404s as absence." >&2
          return 1
        fi ;;
      404)
        if ghcr_json_is "$tmp/tags" '.errors[0].code == "NAME_UNKNOWN"'; then
          echo "::error::ghcr.io/${repository} is not visible to the job token (tag listing: HTTP 404 NAME_UNKNOWN), so its manifest 404s cannot be trusted as absence. Grant this repository read access to the package; if the package genuinely does not exist yet, publish its first image deliberately rather than through this automatic path." >&2
          return 1
        fi
        ghcr_fail "tag listing for ${repository}" "$tmp/tags"
        return 1 ;;
      *)
        ghcr_fail "tag listing for ${repository}" "$tmp/tags"
        return 1 ;;
    esac
  fi
  printf '%s' "$states"
)
