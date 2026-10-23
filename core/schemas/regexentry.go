package schemas

import (
	"fmt"
	"regexp"
	"strings"
	"sync"
)

// RegexEntryPrefix marks a list entry as an RE2 pattern instead of an exact value.
// "regex:^gpt-4.*" allows or blocks every model whose name starts with gpt-4.
const RegexEntryPrefix = "regex:"

// regexEntryCache holds compiled patterns keyed by the raw entry text.
var regexEntryCache sync.Map

// IsRegexEntry reports whether entry carries the regex: prefix.
func IsRegexEntry(entry string) bool {
	return strings.HasPrefix(entry, RegexEntryPrefix)
}

// compileRegexEntry compiles the pattern behind the prefix as a full, case-insensitive match.
func compileRegexEntry(entry string) (*regexp.Regexp, error) {
	if cached, ok := regexEntryCache.Load(entry); ok {
		return cached.(*regexp.Regexp), nil
	}
	pattern := strings.TrimPrefix(entry, RegexEntryPrefix)
	if pattern == "" {
		return nil, fmt.Errorf("regex entry %q has no pattern", entry)
	}
	if pattern == "*" {
		return nil, fmt.Errorf("regex entry %q is not a pattern; use a bare \"*\" to allow or block everything", entry)
	}
	// Compile the pattern on its own first. Inside the anchoring wrapper an unbalanced
	// pattern can close the wrapper's group itself and still compile: "gpt)|(?:claude"
	// becomes "^(?:gpt)|(?:claude)$", whose alternatives are no longer anchored at both
	// ends, so it would match "gpt-unrelated" and "unrelated-claude".
	if _, err := regexp.Compile(pattern); err != nil {
		return nil, fmt.Errorf("regex entry %q does not compile: %v", entry, err)
	}
	re, err := regexp.Compile("(?i)^(?:" + pattern + ")$")
	if err != nil {
		return nil, fmt.Errorf("regex entry %q does not compile: %v", entry, err)
	}
	regexEntryCache.Store(entry, re)
	return re, nil
}

// MatchEntry reports whether a list entry matches value: an exact, case-insensitive
// comparison for plain entries, a full RE2 match for regex: entries. An entry that
// does not compile never matches.
func MatchEntry(entry, value string) bool {
	if !IsRegexEntry(entry) {
		return strings.EqualFold(entry, value)
	}
	re, err := compileRegexEntry(entry)
	if err != nil {
		return false
	}
	return re.MatchString(value)
}

// ValidateRegexEntries returns the first regex: entry in entries that is empty,
// the bare wildcard, or does not compile. Plain entries are not inspected.
func ValidateRegexEntries(entries []string) error {
	for _, entry := range entries {
		if !IsRegexEntry(entry) {
			continue
		}
		if _, err := compileRegexEntry(entry); err != nil {
			return err
		}
	}
	return nil
}
