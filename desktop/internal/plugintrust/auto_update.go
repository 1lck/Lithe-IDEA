package plugintrust

// MayAutoUpdate reports whether the user-approved scope of an installed package
// explicitly covers the next release from the same trusted marketplace index.
// An earlier version is never enough by itself: unknown origins, disk installs,
// additional permissions or changed program declarations require manual review.
func MayAutoUpdate(previous Record, found bool, indexURL string, next Review) bool {
	if !found || previous.Source != Marketplace || previous.MarketplaceIndexURL == "" ||
		indexURL == "" || previous.MarketplaceIndexURL != indexURL ||
		!sameStrings(previous.Permissions, next.Permissions) {
		return false
	}
	same, err := samePrograms(previous.ApprovedPrograms, next.Programs)
	return err == nil && same
}
