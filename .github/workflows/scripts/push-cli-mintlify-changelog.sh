#!/usr/bin/env bash
set -euo pipefail

# Generates the Mintlify changelog for a CLI release as a patch. It never commits,
# pulls or pushes: main requires a reviewed codex-review check, so the patch reaches
# main only through a reviewed PR for the release's docs ticket.
#
# The patch is written outside the checkout (see release-patch-utils.sh), is named
# for the version and the tested commit, and may touch only the new changelog page,
# docs/docs.json and cli/changelog.md. The page is dated from the commit, so a rerun
# for the same commit and version writes the same patch.

VERSION=${1:-}

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.10.0"
  exit 1
fi

VERSION_WITH_PREFIX="cli-v$VERSION"

source "$(dirname "$0")/release-patch-utils.sh"
assert_tested_checkout

# Check if this page already exists in docs/changelogs/
if [ -f "docs/changelogs/$VERSION_WITH_PREFIX.mdx" ]; then
  release_summary "### CLI docs changelog v$VERSION: already on this commit" "" "docs/changelogs/$VERSION_WITH_PREFIX.mdx exists at $(git rev-parse HEAD); no patch."
  exit 0
fi

# Everything the patch may touch. Anything else dirty, before or after, fails the run.
ALLOWLIST=("docs/changelogs/$VERSION_WITH_PREFIX.mdx" docs/docs.json cli/changelog.md)
if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo "::error::the checkout has changes before the changelog is generated:" >&2
  git status --short --untracked-files=all >&2
  exit 1
fi

# Source changelog utilities
source "$(dirname "$0")/changelog-utils.sh"

# The commit's date, not the wall clock, so a rerun writes the same page.
CURRENT_DATE=$(TZ=UTC0 git log -1 --format=%cd --date=format-local:%Y-%m-%d HEAD)

# Get changelog content from cli/changelog.md
CLI_CHANGELOG_PATH="cli/changelog.md"
if [ ! -f "$CLI_CHANGELOG_PATH" ]; then
  echo "❌ CLI changelog not found at $CLI_CHANGELOG_PATH"
  exit 1
fi

CHANGELOG_CONTENT=$(get_file_content "$CLI_CHANGELOG_PATH")
if [ -z "$CHANGELOG_CONTENT" ]; then
  echo "❌ CLI changelog is empty"
  exit 1
fi

# Preparing changelog file
CHANGELOG_BODY="---
title: \"v$VERSION\"
description: \"v$VERSION changelog - $CURRENT_DATE\"
---

<Update label=\"Bifrost CLI\" description=\"v$VERSION\">
$CHANGELOG_CONTENT

</Update>
"

# Write to file
mkdir -p docs/changelogs
echo "$CHANGELOG_BODY" > "docs/changelogs/$VERSION_WITH_PREFIX.mdx"
echo "✅ Created docs/changelogs/$VERSION_WITH_PREFIX.mdx"

# Clear the CLI changelog file after processing
printf '' > "$CLI_CHANGELOG_PATH"
echo "✅ Cleared $CLI_CHANGELOG_PATH"

# Update docs.json to include this new changelog route in the Bifrost CLI menu
route="changelogs/$VERSION_WITH_PREFIX"
if ! grep -q "\"$route\"" docs/docs.json; then
  node -e "
    const fs = require('fs');
    const docs = JSON.parse(fs.readFileSync('docs/docs.json', 'utf8'));
    
    // Semantic version comparison function
    // Extracts version from route/filename and compares in descending order (newest first)
    function compareVersionsDesc(a, b) {
      // Extract route string from string or object
      const routeA = typeof a === 'string' ? a : '';
      const routeB = typeof b === 'string' ? b : '';
      
      // Extract version from route (e.g., 'changelogs/cli-v0.10.0' -> 'cli-v0.10.0')
      const versionA = routeA.split('/').pop() || '';
      const versionB = routeB.split('/').pop() || '';
      
      // Remove 'cli-v' or 'v' prefix and split into parts
      const partsA = versionA.replace(/^(cli-)?v/, '').split(/[.-]/).map(p => {
        const num = parseInt(p, 10);
        return isNaN(num) ? p : num;
      });
      const partsB = versionB.replace(/^(cli-)?v/, '').split(/[.-]/).map(p => {
        const num = parseInt(p, 10);
        return isNaN(num) ? p : num;
      });
      
      // Compare each part (major, minor, patch, pre-release, etc.)
      const maxLength = Math.max(partsA.length, partsB.length);
      for (let i = 0; i < maxLength; i++) {
        // Release vs prerelease: release is newer (no suffix > has suffix)
        if (partsA[i] === undefined && partsB[i] !== undefined) {
          return -1; // A (release) comes first in descending order
        }
        if (partsB[i] === undefined && partsA[i] !== undefined) {
          return 1; // B (release) comes first in descending order
        }
        
        const partA = partsA[i];
        const partB = partsB[i];
        
        // If both are numbers, compare numerically
        if (typeof partA === 'number' && typeof partB === 'number') {
          if (partA !== partB) {
            return partB - partA; // Descending order
          }
        } else {
          // Handle prerelease strings with numeric suffixes (e.g., 'prerelease10')
          const strA = String(partA);
          const strB = String(partB);
          const matchA = strA.match(/^([a-zA-Z]+)(\\d+)$/);
          const matchB = strB.match(/^([a-zA-Z]+)(\\d+)$/);
          
          if (matchA && matchB && matchA[1] === matchB[1]) {
            // Same prefix, compare numbers numerically
            const numA = parseInt(matchA[2], 10);
            const numB = parseInt(matchB[2], 10);
            if (numA !== numB) {
              return numB - numA; // Descending order
            }
          } else if (strA !== strB) {
            return strB.localeCompare(strA); // Descending order
          }
        }
      }
      
      return 0; // Equal
    }
    
    // Sort a pages array by semver (descending)
    function sortPagesBySemver(pages) {
      return pages.slice().sort(compareVersionsDesc);
    }
    
    // Get current month/year
    const releaseDate = new Date('$CURRENT_DATE');
    const currentDate = new Date();
    const releaseMonthYear = releaseDate.toLocaleDateString('en-US', { year: 'numeric', month: 'long' });
    const currentMonthYear = currentDate.toLocaleDateString('en-US', { year: 'numeric', month: 'long' });
    
    // Find the Changelogs tab
    const changelogsTab = docs.navigation.tabs.find(tab => tab.tab === 'Changelogs');
    if (!changelogsTab) {
      console.error('Changelogs tab not found');
      process.exit(1);
    }
    
    // Find the Bifrost CLI menu item
    const cliMenuItem = changelogsTab.menu.find(item => item.item === 'Bifrost CLI');
    if (!cliMenuItem) {
      console.error('Bifrost CLI menu item not found');
      process.exit(1);
    }
    
    // Get all top-level entries and existing groups
    const topLevelEntries = cliMenuItem.pages.filter(p => typeof p === 'string');
    const existingGroups = cliMenuItem.pages.filter(p => typeof p === 'object');
    
    // Check if we need to group existing top-level entries
    if (topLevelEntries.length > 0) {
      // Get the month of the first top-level entry (they should all be from same month)
      const firstEntryPath = topLevelEntries[0].replace('changelogs/', '') + '.mdx';
      const firstEntryFile = 'docs/changelogs/' + firstEntryPath;
      
      let topLevelMonth = null;
      try {
        const content = fs.readFileSync(firstEntryFile, 'utf8');
        const descMatch = content.match(/description:\\s*\"[^\"]*?(\\d{4}-\\d{2}-\\d{2})[^\"]*\"/);
        if (descMatch) {
          const entryDate = new Date(descMatch[1]);
          topLevelMonth = entryDate.toLocaleDateString('en-US', { year: 'numeric', month: 'long' });
        }
      } catch (e) {
        console.log(\`Warning: Could not read entry file \${firstEntryFile}: \${e.message}\`);
      }
      
      // Only group if the month has changed
      if (topLevelMonth && topLevelMonth !== releaseMonthYear) {
        console.log(\`📦 Month changed from \${topLevelMonth} to \${releaseMonthYear}\`);
        console.log(\`📦 Grouping \${topLevelEntries.length} top-level entries into \${topLevelMonth} group...\`);
        
        // Create a group for all existing top-level entries
        const previousMonthGroup = {
          group: topLevelMonth,
          pages: sortPagesBySemver(topLevelEntries)
        };
        
        // Add this group at the top of existing groups
        existingGroups.unshift(previousMonthGroup);
        console.log(\`✅ Created \${topLevelMonth} group with \${topLevelEntries.length} entries (sorted)\`);
        
        // Clear top-level entries (they're now in the group)
        cliMenuItem.pages = existingGroups;
      } else {
        console.log(\`📋 Same month (\${releaseMonthYear}), keeping existing top-level entries\`);
        // Keep existing structure (top-level entries + groups)
        cliMenuItem.pages = [...topLevelEntries, ...existingGroups];
      }
    }
    
    const newRoute = '$route';
    
    // Add the new changelog at the top level
    cliMenuItem.pages.unshift(newRoute);
    console.log(\`✅ Added \${newRoute} to top level\`);
    
    // Sort the top-level pages array by semver
    const topLevelPages = cliMenuItem.pages.filter(p => typeof p === 'string');
    const groupPages = cliMenuItem.pages.filter(p => typeof p === 'object');
    
    if (topLevelPages.length > 0) {
      const sortedTopLevel = sortPagesBySemver(topLevelPages);
      cliMenuItem.pages = [...sortedTopLevel, ...groupPages];
      console.log(\`✅ Sorted \${topLevelPages.length} top-level pages by semver\`);
    }
    
    // Sort each group's pages by semver
    for (const group of groupPages) {
      if (group.pages && Array.isArray(group.pages)) {
        group.pages = sortPagesBySemver(group.pages);
      }
    }
    
    fs.writeFileSync('docs/docs.json', JSON.stringify(docs, null, 2) + '\n');
    console.log('✅ Updated docs.json');
  "
fi

write_release_patch cli-docs-changelog "$VERSION" "${ALLOWLIST[@]}"
release_summary \
  "### CLI docs changelog v$VERSION: pending, not published" \
  "" \
  "Generated from $(git rev-parse HEAD) but not committed: main takes it only through a reviewed PR." \
  "Patch artifact: \`$(basename "$RELEASE_PATCH")\` (blob $(git hash-object "$RELEASE_PATCH"))."
echo "::warning::CLI docs changelog v$VERSION is pending, not published: apply $(basename "$RELEASE_PATCH") in a reviewed PR"
