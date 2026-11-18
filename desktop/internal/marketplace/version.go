package marketplace

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// NewerOffered uses the release order already validated by Core. It does not
// infer ordering from version strings, which may contain prerelease identifiers.
func NewerOffered(plugin core.MarketplacePlugin, installed string) bool {
	offered := plugin.Availability.Version
	if offered == "" {
		offered = plugin.LatestVersion
	}
	if plugin.Availability.Status != "available" || offered == "" || offered == installed {
		return false
	}
	seenOffered := false
	for _, version := range plugin.Versions {
		switch version.Version {
		case offered:
			seenOffered = true
		case installed:
			return seenOffered
		}
	}
	return false
}
