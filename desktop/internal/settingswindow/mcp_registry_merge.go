package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// mergeRegistryWithFeatured is the list a search shows. Featured entries that match the query
// come first, then the registry's results, without any entry that is already listed above it.
// Paging still follows the registry's cursor; this only arranges what is on screen.
func mergeRegistryWithFeatured(featured []core.McpRegistryEntry, query string, results []core.McpRegistryEntry) []core.McpRegistryEntry {
	listed := make(map[string]bool, len(featured)+len(results))
	out := make([]core.McpRegistryEntry, 0, len(featured)+len(results))
	needle := strings.ToLower(strings.TrimSpace(query))
	for _, entry := range featured {
		if needle != "" && !registryEntryMatches(entry, needle) {
			continue
		}
		if entry.ID != "" {
			listed[entry.ID] = true
		}
		out = append(out, entry)
	}
	for _, entry := range results {
		if entry.ID != "" {
			if listed[entry.ID] {
				continue
			}
			listed[entry.ID] = true
		}
		out = append(out, entry)
	}
	return out
}

// registryEntryMatches reports whether a featured entry's identifier, title or summary contains
// the lowercased needle.
func registryEntryMatches(entry core.McpRegistryEntry, needle string) bool {
	for _, field := range []string{entry.ID, entry.Title, entry.Summary} {
		if strings.Contains(strings.ToLower(field), needle) {
			return true
		}
	}
	return false
}
