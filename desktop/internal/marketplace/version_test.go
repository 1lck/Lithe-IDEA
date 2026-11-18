package marketplace

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestNewerOfferedOnlyUsesKnownOrderedReleases(t *testing.T) {
	plugin := core.MarketplacePlugin{
		LatestVersion: "2.0.0",
		Availability:  core.MarketplaceAvailability{Status: "available", Version: "2.0.0"},
		Versions:      []core.MarketplaceVersion{{Version: "2.0.0"}, {Version: "1.8.0"}, {Version: "1.7.0"}},
	}
	for _, tc := range []struct {
		name, installed string
		want            bool
	}{
		{"older", "1.8.0", true},
		{"current", "2.0.0", false},
		{"not listed", "1.6.0", false},
		{"newer or development", "3.0.0", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := NewerOffered(plugin, tc.installed); got != tc.want {
				t.Fatalf("NewerOffered(%q) = %v, want %v", tc.installed, got, tc.want)
			}
		})
	}
	plugin.Availability.Status = "unsupported"
	if NewerOffered(plugin, "1.8.0") {
		t.Fatal("unavailable releases must not be downloaded automatically")
	}
}
