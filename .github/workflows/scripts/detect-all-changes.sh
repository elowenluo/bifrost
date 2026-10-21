#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Detect what components need to be released based on version changes
# Usage: ./detect-all-changes.sh
echo "🔍 Auto-detecting version changes across all components..."

# Initialize outputs
CORE_NEEDS_RELEASE="false"
FRAMEWORK_NEEDS_RELEASE="false"
PLUGINS_NEED_RELEASE="false"
BIFROST_HTTP_NEEDS_RELEASE="false"
DOCKER_NEEDS_RELEASE="false"
CHANGED_PLUGINS="[]"

# Every version read here is echoed into GITHUB_OUTPUT and then interpolated with
# ${{ }} into `run:` blocks throughout the release pipeline. GitHub expands ${{ }}
# TEXTUALLY, before the shell parses the line, so quoting at the call site cannot
# contain a value carrying command substitution - "$(id)" still runs. Validating once
# here, where the value enters the pipeline, is what makes every downstream
# interpolation safe; there are dozens of them and guarding each is neither reliable
# nor reviewable.
validate_version() {
  local value="$1"
  local name="$2"
  # Anchored, and a regex rather than a glob: a `case` pattern like
  # [0-9]*.[0-9]*.[0-9]* looks structural but is not, because each `*` matches
  # anything - it accepted 1x.2.3, 1.2.3rc1 and 1.2.3.4. Three numeric components are
  # required, and a suffix is permitted only after PATCH and only when introduced by
  # `-` or `+`. The suffix quantifier is `+`, not `*`: a separator introducing nothing
  # (1.2.3- / 1.2.3+) is malformed per Semantic Versioning 2.0.0 clauses 9 and 10,
  # which both require that identifiers MUST NOT be empty - and it is the shape a
  # truncated version file takes, which is worth catching here rather than at tag time.
  if [[ ! "$value" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+_-]+)?$ ]]; then
    echo "::error::refusing malformed $name version: '$value' (expected MAJOR.MINOR.PATCH, optionally v-prefixed, with an optional -suffix)" >&2
    return 1
  fi
  # A second, independent check on the character set. The regex above already implies
  # it, so this is belt-and-braces: it is what keeps a future loosening of the shape
  # pattern from silently re-admitting shell metacharacters. The set is deliberately wide
  # enough for the prerelease shapes this repo actually ships - v2.0.0-prerelease1,
  # and multi-hyphen forms like v1.5.0-prerelease3-ajhfix-base - because a guard that
  # false-rejects blocks a release, and every character admitted here is inert to a
  # shell.
  case "$value" in
    *[!v0-9.A-Za-z_+-]*)
      echo "::error::refusing $name version with unexpected characters: '$value'" >&2
      return 1
      ;;
  esac
}

# Plugin names travel the same way and by a sharper edge: they are collected into the
# changed-plugins JSON and interpolated as '${{ ... }}' inside single quotes at the
# release-all-plugins.sh call site. jq -R escapes double quotes and backslashes when
# building that JSON but leaves single quotes alone, so a name containing one closes
# the shell string. A plugin name is a directory name - it has no business containing
# anything but the characters below.
validate_plugin_name() {
  local value="$1"
  case "$value" in
    "")
      echo "::error::refusing empty plugin name" >&2
      return 1
      ;;
    *[!A-Za-z0-9._-]*)
      echo "::error::refusing plugin name with unexpected characters: '$value'" >&2
      return 1
      ;;
    *..*)
      echo "::error::refusing plugin name containing '..': '$value'" >&2
      return 1
      ;;
  esac
}

# Get current versions
CORE_VERSION=$(cat core/version)
FRAMEWORK_VERSION=$(cat framework/version)
TRANSPORT_VERSION=$(cat transports/version)

validate_version "$CORE_VERSION" "core"
validate_version "$FRAMEWORK_VERSION" "framework"
validate_version "$TRANSPORT_VERSION" "transport"

echo "📦 Current versions:"
echo "   Core: $CORE_VERSION"
echo "   Framework: $FRAMEWORK_VERSION"
echo "   Transport: $TRANSPORT_VERSION"

START_FROM="none"

has_nonempty_changelog() {
  local changelog_file="$1"
  if [ ! -f "$changelog_file" ]; then
    return 1
  fi

  local content
  content=$(grep -v '^<!--' "$changelog_file" | grep -v '^-->' | tr -d '[:space:]' || true)
  [ -n "$content" ]
}

# Check Core
echo ""
echo "🔧 Checking core..."
CORE_TAG="core/v${CORE_VERSION}"
if git rev-parse --verify "$CORE_TAG" >/dev/null 2>&1; then
  echo "   ⏭️ Tag $CORE_TAG already exists"
else
  # Extract major.minor track from version (e.g., "1.3.55" -> "1.3", "1.4.0-prerelease1" -> "1.4")
  CORE_BASE_VERSION=$(echo "$CORE_VERSION" | sed 's/-.*$//')
  CORE_MAJOR_MINOR=$(echo "$CORE_BASE_VERSION" | cut -d. -f1,2)
  echo "   🔍 Checking track: ${CORE_MAJOR_MINOR}.x"
  
  # Get previous version in the same track
  LATEST_CORE_TAG=$(git tag -l "core/v${CORE_MAJOR_MINOR}.*" | sort -V | tail -1)
  echo "🏷️ Latest core tag in track ${CORE_MAJOR_MINOR}.x: $LATEST_CORE_TAG"
  if [ -z "$LATEST_CORE_TAG" ]; then
    if has_nonempty_changelog "core/changelog.md"; then
      echo "   ✅ First core release in track ${CORE_MAJOR_MINOR}.x: $CORE_VERSION"
      CORE_NEEDS_RELEASE="true"
    else
      echo "   ⏭️ Core changelog empty, skipping core release"
    fi
  else
    if [[ "$CORE_VERSION" == *"-"* ]]; then
      # current_version has prerelease, so include all versions but prefer stable
      ALL_TAGS=$(git tag -l "core/v${CORE_MAJOR_MINOR}.*" | sort -V)
      STABLE_TAGS=$(echo "$ALL_TAGS" | grep -v '\-' || true)
      PRERELEASE_TAGS=$(echo "$ALL_TAGS" | grep '\-' || true)
      if [ -n "$STABLE_TAGS" ]; then
        # Get the highest stable version
        LATEST_CORE_TAG=$(echo "$STABLE_TAGS" | tail -1)
        echo "latest core tag (stable preferred): $LATEST_CORE_TAG"
      else
        # No stable versions, get highest prerelease
        LATEST_CORE_TAG=$(echo "$PRERELEASE_TAGS" | tail -1)
        echo "latest core tag (prerelease only): $LATEST_CORE_TAG"
      fi
    else
      # VERSION has no prerelease, so only consider stable releases in same track
      LATEST_CORE_TAG=$(git tag -l "core/v${CORE_MAJOR_MINOR}.*" | grep -v '\-' | sort -V | tail -1 || true)
      echo "latest core tag (stable only): $LATEST_CORE_TAG"
    fi
    PREVIOUS_CORE_VERSION=${LATEST_CORE_TAG#core/v}
    echo "   📋 Previous: $PREVIOUS_CORE_VERSION, Current: $CORE_VERSION"
    # Fixed: Use head -1 instead of tail -1 for your sort -V behavior, and check against current version
    if [ "$(printf '%s\n' "$PREVIOUS_CORE_VERSION" "$CORE_VERSION" | sort -V | tail -1)" = "$CORE_VERSION" ] && [ "$PREVIOUS_CORE_VERSION" != "$CORE_VERSION" ]; then
      if has_nonempty_changelog "core/changelog.md"; then
        echo "   ✅ Core version incremented: $PREVIOUS_CORE_VERSION → $CORE_VERSION"
        CORE_NEEDS_RELEASE="true"
      else
        echo "   ⏭️ Core changelog empty, skipping core release"
      fi
    else
      echo "   ⏭️ No core version increment"
    fi
  fi
fi

# Check Framework
echo ""
echo "📦 Checking framework..."
FRAMEWORK_TAG="framework/v${FRAMEWORK_VERSION}"
if git rev-parse --verify "$FRAMEWORK_TAG" >/dev/null 2>&1; then
  echo "   ⏭️ Tag $FRAMEWORK_TAG already exists"
else
  # Extract major.minor track from version (e.g., "1.3.55" -> "1.3", "1.4.0-prerelease1" -> "1.4")
  FRAMEWORK_BASE_VERSION=$(echo "$FRAMEWORK_VERSION" | sed 's/-.*$//')
  FRAMEWORK_MAJOR_MINOR=$(echo "$FRAMEWORK_BASE_VERSION" | cut -d. -f1,2)
  echo "   🔍 Checking track: ${FRAMEWORK_MAJOR_MINOR}.x"
  
  LATEST_FRAMEWORK_TAG=""
  if [[ "$FRAMEWORK_VERSION" == *"-"* ]]; then
    # current_version has prerelease, so include all versions but prefer stable
    ALL_TAGS=$(git tag -l "framework/v${FRAMEWORK_MAJOR_MINOR}.*" | sort -V)
    STABLE_TAGS=$(echo "$ALL_TAGS" | grep -v '\-' || true)
    PRERELEASE_TAGS=$(echo "$ALL_TAGS" | grep '\-' || true)
    if [ -n "$STABLE_TAGS" ]; then
      # Get the highest stable version
      LATEST_FRAMEWORK_TAG=$(echo "$STABLE_TAGS" | tail -1)
      echo "latest framework tag (stable preferred): $LATEST_FRAMEWORK_TAG"
    else
      # No stable versions, get highest prerelease
      LATEST_FRAMEWORK_TAG=$(echo "$PRERELEASE_TAGS" | tail -1)
      echo "latest framework tag (prerelease only): $LATEST_FRAMEWORK_TAG"
    fi
  else
    # VERSION has no prerelease, so only consider stable releases in same track
    LATEST_FRAMEWORK_TAG=$(git tag -l "framework/v${FRAMEWORK_MAJOR_MINOR}.*" | grep -v '\-' | sort -V | tail -1 || true)
    echo "latest framework tag (stable only): $LATEST_FRAMEWORK_TAG"
  fi
  if [ -z "$LATEST_FRAMEWORK_TAG" ]; then
    if has_nonempty_changelog "framework/changelog.md"; then
      echo "   ✅ First framework release in track ${FRAMEWORK_MAJOR_MINOR}.x: $FRAMEWORK_VERSION"
      FRAMEWORK_NEEDS_RELEASE="true"
    else
      echo "   ⏭️ Framework changelog empty, skipping framework release"
    fi
  else
    PREVIOUS_FRAMEWORK_VERSION=${LATEST_FRAMEWORK_TAG#framework/v}
    echo "   📋 Previous: $PREVIOUS_FRAMEWORK_VERSION, Current: $FRAMEWORK_VERSION"
    # Fixed: Use head -1 instead of tail -1 for your sort -V behavior, and check against current version
    if [ "$(printf '%s\n' "$PREVIOUS_FRAMEWORK_VERSION" "$FRAMEWORK_VERSION" | sort -V | tail -1)" = "$FRAMEWORK_VERSION" ] && [ "$PREVIOUS_FRAMEWORK_VERSION" != "$FRAMEWORK_VERSION" ]; then
      if has_nonempty_changelog "framework/changelog.md"; then
        echo "   ✅ Framework version incremented: $PREVIOUS_FRAMEWORK_VERSION → $FRAMEWORK_VERSION"
        FRAMEWORK_NEEDS_RELEASE="true"
      else
        echo "   ⏭️ Framework changelog empty, skipping framework release"
      fi
    else
      echo "   ⏭️ No framework version increment"
    fi
  fi
fi

# Check Plugins
echo ""
echo "🔌 Checking plugins..."
PLUGIN_CHANGES=()

for plugin_dir in plugins/*/; do
  if [ ! -d "$plugin_dir" ]; then
    continue
  fi

  plugin_name=$(basename "$plugin_dir")
  validate_plugin_name "$plugin_name"
  version_file="${plugin_dir}version"

  if [ ! -f "$version_file" ]; then
    echo "   ⚠️ No version file for: $plugin_name"
    continue
  fi

  current_version=$(cat "$version_file" | tr -d '\n\r')
  if [ -z "$current_version" ]; then
    echo "   ⚠️ Empty version file for: $plugin_name"
    continue
  fi
  # A missing or empty version file means "this plugin is not versioned" and is skipped
  # above. A version file that exists and holds something malformed is a different
  # thing - a repo error - so it stops the run rather than silently dropping the plugin
  # from the release, which would be far harder to notice.
  validate_version "$current_version" "plugin $plugin_name"

  tag_name="plugins/${plugin_name}/v${current_version}"
  echo "   📦 Plugin: $plugin_name (v$current_version)"

  if git rev-parse --verify "$tag_name" >/dev/null 2>&1; then
    echo "      ⏭️ Tag already exists"
    continue
  fi

  # Extract major.minor track from version (e.g., "1.3.55" -> "1.3", "1.4.0-prerelease1" -> "1.4")
  plugin_base_version=$(echo "$current_version" | sed 's/-.*$//')
  plugin_major_minor=$(echo "$plugin_base_version" | cut -d. -f1,2)
  echo "      🔍 Checking track: ${plugin_major_minor}.x"

  if [[ "$current_version" == *"-"* ]]; then
    # current_version has prerelease, so include all versions but prefer stable
    ALL_TAGS=$(git tag -l "plugins/${plugin_name}/v${plugin_major_minor}.*" | sort -V)
    STABLE_TAGS=$(echo "$ALL_TAGS" | grep -v '\-' || true)
    PRERELEASE_TAGS=$(echo "$ALL_TAGS" | grep '\-' || true)

    if [ -n "$STABLE_TAGS" ]; then
      # Get the highest stable version
      LATEST_PLUGIN_TAG=$(echo "$STABLE_TAGS" | tail -1)
      echo "latest plugin tag (stable preferred): $LATEST_PLUGIN_TAG"
    else
      # No stable versions, get highest prerelease
      LATEST_PLUGIN_TAG=$(echo "$PRERELEASE_TAGS" | tail -1)
      echo "latest plugin tag (prerelease only): $LATEST_PLUGIN_TAG"
    fi
  else
    # VERSION has no prerelease, so only consider stable releases in same track
    LATEST_PLUGIN_TAG=$(git tag -l "plugins/${plugin_name}/v${plugin_major_minor}.*" | grep -v '\-' | sort -V | tail -1 || true)
    echo "latest plugin tag (stable only): $LATEST_PLUGIN_TAG"
  fi

  latest_tag=$LATEST_PLUGIN_TAG
  if [ -z "$latest_tag" ]; then
    if has_nonempty_changelog "${plugin_dir}changelog.md"; then
      echo "      ✅ First release in track ${plugin_major_minor}.x"
      PLUGIN_CHANGES+=("$plugin_name")
    else
      echo "      ⏭️ Changelog empty for $plugin_name, skipping plugin release"
    fi
  else
    previous_version=${latest_tag#plugins/${plugin_name}/v}
    echo "previous version: $previous_version"
    echo "current version: $current_version"
    echo "latest tag: $latest_tag"
    if [ "$(printf '%s\n' "$previous_version" "$current_version" | sort -V | tail -1)" = "$current_version" ] && [ "$previous_version" != "$current_version" ]; then
      if has_nonempty_changelog "${plugin_dir}changelog.md"; then
        echo "      ✅ Version incremented: $previous_version → $current_version"
        PLUGIN_CHANGES+=("$plugin_name")
      else
        echo "      ⏭️ Changelog empty for $plugin_name, skipping plugin release"
      fi
    else
      echo "      ⏭️ No version increment"
    fi
  fi
done

if [ ${#PLUGIN_CHANGES[@]} -gt 0 ]; then
  PLUGINS_NEED_RELEASE="true"
  echo "   🔄 Plugins with changes: ${PLUGIN_CHANGES[*]}"
else
  echo "   ⏭️ No plugin changes detected"
fi

# Check Bifrost HTTP
echo ""
echo "🚀 Checking bifrost-http..."
TRANSPORT_TAG="transports/v${TRANSPORT_VERSION}"
DOCKER_TAG_EXISTS="false"

# Check if Git tag exists
GIT_TAG_EXISTS="false"
if git rev-parse --verify "$TRANSPORT_TAG" >/dev/null 2>&1; then
  echo "   ⏭️ Git tag $TRANSPORT_TAG already exists"
  GIT_TAG_EXISTS="true"
fi

# Check if Docker tag exists on GHCR
#
# docker-needs-release=true is what lets this pipeline push v<version> to ghcr.io, and
# pushing a tag that already exists replaces a published image with a rebuild. So
# "absent" has to be a definite answer from the registry, never what is left over when a
# lookup fails. ghcr.io/txehq/bifrost is private: an anonymous token request for it is
# refused with 401, which an unauthenticated probe used to read as "absent" on every run.
#
# Measured against ghcr.io (2026-10-22, TXE-4819) with an authorized token: an existing
# tag answers 200 and a missing one 404 MANIFEST_UNKNOWN - but so does any tag in a
# repository that does not exist or that the token cannot see. tags/list tells those
# apart (200 for a visible repository, 404 NAME_UNKNOWN otherwise). So a tag is absent
# only when its manifest answers 404 MANIFEST_UNKNOWN and the repository's tag listing
# answers 200 under the same token. Any other outcome stops the job rather than guess.
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

# The registry error code from a response body (e.g. MANIFEST_UNKNOWN), or nothing.
ghcr_error_code() {
  jq -r '.errors[0].code // empty' "$1" 2>/dev/null | tr -cd 'A-Z_' | cut -c1-40 || true
}

# ghcr_fail <what> <body file>: explain an answer that is not definitive. The response
# body is never printed - only its registry error code - so nothing secret reaches the log.
ghcr_fail() {
  local what="$1" code
  code=$(ghcr_error_code "$2")
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

# ghcr_tag_state <owner/name> <tag>: prints "present" or "absent" and returns 0 only on a
# definitive registry answer; otherwise explains on stderr and returns 1. The body runs in
# a subshell so its temporary directory is removed however it returns.
ghcr_tag_state() (
  repository="$1"
  tag="$2"
  if [[ ! "$repository" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "::error::refusing malformed GHCR repository name: '${repository}'" >&2
    return 1
  fi
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "::error::GITHUB_TOKEN is not set, so ghcr.io/${repository} cannot be queried and the state of tag ${tag} is unknown. The release pipeline passes the job token; for a local run, export a token with read:packages as GITHUB_TOKEN." >&2
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
  bearer=$(jq -r '.token // .access_token // empty' "$tmp/token" 2>/dev/null) || bearer=""
  # RFC 6750 b64token, which also keeps the value inert inside the quoted config line.
  if [[ ! "$bearer" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "::error::GHCR token exchange for ${repository} answered HTTP 200 with no usable token." >&2
    return 1
  fi
  auth="header = \"Authorization: Bearer ${bearer}\""

  ghcr_request "manifest lookup" "$auth" "$tmp/manifest" \
    "https://ghcr.io/v2/${repository}/manifests/${tag}" -H "Accept: ${GHCR_ACCEPT}"
  case "$GHCR_STATUS" in
    200)
      if ! jq -e '.schemaVersion' "$tmp/manifest" >/dev/null 2>&1; then
        echo "::error::GHCR manifest lookup for ${repository}:${tag} answered HTTP 200 without a manifest body; refusing to guess the tag's state." >&2
        return 1
      fi
      echo "present"
      return 0 ;;
    404)
      if [ "$(ghcr_error_code "$tmp/manifest")" != "MANIFEST_UNKNOWN" ]; then
        ghcr_fail "manifest lookup for ${repository}:${tag}" "$tmp/manifest"
        return 1
      fi ;;
    *)
      ghcr_fail "manifest lookup for ${repository}:${tag}" "$tmp/manifest"
      return 1 ;;
  esac

  ghcr_request "tag listing" "$auth" "$tmp/tags" "https://ghcr.io/v2/${repository}/tags/list?n=1"
  case "$GHCR_STATUS" in
    200)
      listed=$(jq -r '.name // empty' "$tmp/tags" 2>/dev/null | tr -cd 'A-Za-z0-9._/-') || listed=""
      if [ "$listed" != "$repository" ]; then
        echo "::error::GHCR tag listing for ${repository} answered HTTP 200 for '${listed}'; refusing to read the manifest 404 for ${tag} as absence." >&2
        return 1
      fi
      echo "absent"
      return 0 ;;
    404)
      if [ "$(ghcr_error_code "$tmp/tags")" = "NAME_UNKNOWN" ]; then
        echo "::error::ghcr.io/${repository} is not visible to the job token (tag listing: HTTP 404 NAME_UNKNOWN), so the manifest 404 for ${tag} cannot be trusted as absence. Grant this repository read access to the package; if the package genuinely does not exist yet, publish its first image deliberately rather than through this automatic path." >&2
        return 1
      fi
      ghcr_fail "tag listing for ${repository}" "$tmp/tags"
      return 1 ;;
    *)
      ghcr_fail "tag listing for ${repository}" "$tmp/tags"
      return 1 ;;
  esac
)

GHCR_OWNER="${GITHUB_REPOSITORY_OWNER:-capsohq}"
GHCR_REPOSITORY="${GHCR_OWNER}/bifrost"
echo "   🐳 Checking GHCR for tag v${TRANSPORT_VERSION} in ${GHCR_REPOSITORY}..."
if ! GHCR_TAG_STATE=$(ghcr_tag_state "$GHCR_REPOSITORY" "v${TRANSPORT_VERSION}"); then
  echo "   ❌ Could not establish whether Docker tag v${TRANSPORT_VERSION} exists on GHCR; stopping rather than risk overwriting a published image" >&2
  exit 1
fi

if [ "$GHCR_TAG_STATE" = "present" ]; then
  echo "   ⏭️ Docker tag v${TRANSPORT_VERSION} already exists on GHCR"
  DOCKER_TAG_EXISTS="true"
else
  echo "   ❌ Docker tag v${TRANSPORT_VERSION} confirmed absent on GHCR"
fi

# Determine if release is needed
if [ "$GIT_TAG_EXISTS" = "true" ] && [ "$DOCKER_TAG_EXISTS" = "true" ]; then
  echo "   ⏭️ Both Git tag and Docker image exist - no release needed"
else
  # Extract major.minor track from version (e.g., "1.3.55" -> "1.3", "1.4.0-prerelease1" -> "1.4")
  TRANSPORT_BASE_VERSION=$(echo "$TRANSPORT_VERSION" | sed 's/-.*$//')
  TRANSPORT_MAJOR_MINOR=$(echo "$TRANSPORT_BASE_VERSION" | cut -d. -f1,2)
  echo "   🔍 Checking track: ${TRANSPORT_MAJOR_MINOR}.x"
  
  # Get all transport tags in the same track, prioritize stable over prerelease for same base version
  ALL_TRANSPORT_TAGS=$(git tag -l "transports/v${TRANSPORT_MAJOR_MINOR}.*" | sort -V)
  
  # Function to get base version (remove prerelease suffix)
  get_base_version() {
    echo "$1" | sed 's/-.*$//'
  }
  
  # Find the latest version, prioritizing stable over prerelease
  LATEST_TRANSPORT_TAG=""
  LATEST_BASE_VERSION=""
  
  for tag in $ALL_TRANSPORT_TAGS; do
    version=${tag#transports/v}
    base_version=$(get_base_version "$version")
    
    # If this base version is newer, or same base version but current is stable and we had prerelease
    if [ -z "$LATEST_BASE_VERSION" ] || \
       [ "$(printf '%s\n' "$LATEST_BASE_VERSION" "$base_version" | sort -V | tail -1)" = "$base_version" ]; then
      
      if [ "$base_version" = "$LATEST_BASE_VERSION" ]; then
        # Same base version - prefer stable (no hyphen) over prerelease, otherwise take the later one
        if [[ "$version" != *"-"* ]]; then
          # Current is stable, always prefer it
          LATEST_TRANSPORT_TAG="$tag"
        elif [[ "${LATEST_TRANSPORT_TAG#transports/v}" == *"-"* ]]; then
          # Both are prereleases, take the later one (thanks to sort -V)
          LATEST_TRANSPORT_TAG="$tag"
        fi
      else
        # New base version is higher
        LATEST_TRANSPORT_TAG="$tag"
        LATEST_BASE_VERSION="$base_version"
      fi
    fi
  done
  
  if [ -n "$LATEST_TRANSPORT_TAG" ]; then
    echo "   🏷️ Latest transport tag: $LATEST_TRANSPORT_TAG"
  fi
  if [ -z "$LATEST_TRANSPORT_TAG" ]; then
    echo "   ✅ First transport release in track ${TRANSPORT_MAJOR_MINOR}.x: $TRANSPORT_VERSION"
    if [ "$GIT_TAG_EXISTS" = "false" ]; then
      if has_nonempty_changelog "transports/changelog.md"; then
        echo "   🏷️  Git tag missing - transport release needed"
        BIFROST_HTTP_NEEDS_RELEASE="true"
      else
        echo "   ⏭️ Transport changelog empty, skipping transport release"
      fi
    fi
  else
    PREVIOUS_TRANSPORT_VERSION=${LATEST_TRANSPORT_TAG#transports/v}
    echo "   📋 Previous: $PREVIOUS_TRANSPORT_VERSION, Current: $TRANSPORT_VERSION"
    
    # Function to compare versions with proper prerelease handling
    # Returns 0 if $1 < $2, 1 otherwise
    version_less_than() {
      local v1="$1"
      local v2="$2"
      
      # Extract base versions (remove prerelease suffix)
      local base1=$(echo "$v1" | sed 's/-.*$//')
      local base2=$(echo "$v2" | sed 's/-.*$//')
      
      # Compare base versions
      if [ "$base1" != "$base2" ]; then
        # Different base versions, use sort -V
        [ "$(printf '%s\n' "$base1" "$base2" | sort -V | head -1)" = "$base1" ]
        return $?
      fi
      
      # Same base version, check prereleases
      local pre1=$(echo "$v1" | grep -o '\-.*$' || echo "")
      local pre2=$(echo "$v2" | grep -o '\-.*$' || echo "")
      
      if [ -z "$pre1" ] && [ -n "$pre2" ]; then
        # v1 is stable, v2 is prerelease: v2 < v1
        return 1
      elif [ -n "$pre1" ] && [ -z "$pre2" ]; then
        # v1 is prerelease, v2 is stable: v1 < v2
        return 0
      elif [ -n "$pre1" ] && [ -n "$pre2" ]; then
        # Both prereleases, compare them
        [ "$(printf '%s\n' "$pre1" "$pre2" | sort -V | head -1)" = "$pre1" ]
        return $?
      else
        # Both stable and same base: equal
        return 1
      fi
    }
    
    # Check if current version is greater than previous
    if version_less_than "$PREVIOUS_TRANSPORT_VERSION" "$TRANSPORT_VERSION"; then
      echo "   ✅ Transport version incremented: $PREVIOUS_TRANSPORT_VERSION → $TRANSPORT_VERSION"
      if [ "$GIT_TAG_EXISTS" = "false" ]; then
        if has_nonempty_changelog "transports/changelog.md"; then
          echo "   🏷️  Git tag missing - transport release needed"
          BIFROST_HTTP_NEEDS_RELEASE="true"
        else
          echo "   ⏭️ Transport changelog empty, skipping transport release"
        fi
      fi
    else
      echo "   ⏭️ No transport version increment"
    fi
  fi
fi
  
# Check if Docker image needs to be built (independent of transport release)
if [ "$DOCKER_TAG_EXISTS" = "false" ]; then
  echo "   🐳 Docker image missing - docker release needed"
  DOCKER_NEEDS_RELEASE="true"
fi


# Convert plugin array to JSON (compact format)
if [ ${#PLUGIN_CHANGES[@]} -eq 0 ]; then
  CHANGED_PLUGINS_JSON="[]"
else
  CHANGED_PLUGINS_JSON=$(printf '%s\n' "${PLUGIN_CHANGES[@]}" | jq -R . | jq -s -c .)
fi

echo "CHANGED_PLUGINS_JSON: $CHANGED_PLUGINS_JSON"

# Summary
echo ""
echo "📋 Release Summary:"
echo "   Core: $CORE_NEEDS_RELEASE (v$CORE_VERSION)"
echo "   Framework: $FRAMEWORK_NEEDS_RELEASE (v$FRAMEWORK_VERSION)"
echo "   Plugins: $PLUGINS_NEED_RELEASE (${#PLUGIN_CHANGES[@]} plugins)"
echo "   Bifrost HTTP: $BIFROST_HTTP_NEEDS_RELEASE (v$TRANSPORT_VERSION)"
echo "   Docker: $DOCKER_NEEDS_RELEASE (v$TRANSPORT_VERSION)"

# Set outputs (only when running in GitHub Actions)
# Version strings are read straight out of the repo's version files and are then
# interpolated by callers into shell commands (the R2 upload steps, the changelog
# push, the docker manifest). A value carrying a quote, a space or a newline would
# break out of the generated command, and GITHUB_OUTPUT is line-oriented so a
# newline would additionally forge an extra output line. Nothing downstream can
# defend against that once it is written, so it is rejected here, at the single
# point where these values enter the workflow.
for _pair in "core:$CORE_VERSION" "framework:$FRAMEWORK_VERSION" "transport:$TRANSPORT_VERSION"; do
  _name="${_pair%%:*}"
  _value="${_pair#*:}"
  case "$_value" in
    "") continue ;;
    *[!0-9A-Za-z.+_-]*)
      echo "❌ refusing to emit $_name version with unexpected characters: $_value" >&2
      exit 1
      ;;
  esac
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "core-needs-release=$CORE_NEEDS_RELEASE"
    echo "framework-needs-release=$FRAMEWORK_NEEDS_RELEASE"
    echo "plugins-need-release=$PLUGINS_NEED_RELEASE"
    echo "bifrost-http-needs-release=$BIFROST_HTTP_NEEDS_RELEASE"
    echo "docker-needs-release=$DOCKER_NEEDS_RELEASE"
    echo "changed-plugins=$CHANGED_PLUGINS_JSON"
    echo "core-version=$CORE_VERSION"
    echo "framework-version=$FRAMEWORK_VERSION"
    echo "transport-version=$TRANSPORT_VERSION"
  } >> "$GITHUB_OUTPUT"
else
  echo "ℹ️ GITHUB_OUTPUT not set; skipping outputs write (local run)"
fi
