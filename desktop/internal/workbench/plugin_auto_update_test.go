package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

func TestAutoUpdateCandidatesRequireMatchingApprovedSourceAndNewerRelease(t *testing.T) {
	const source = "https://example.test/index.json"
	entries := []pluginmanager.Entry{
		{Installed: pluginpkg.Installed{ID: "dev.lithe.test.ready", Version: "1.0.0"}, Enabled: true},
		{Installed: pluginpkg.Installed{ID: "dev.lithe.test.disabled", Version: "1.0.0"}, Enabled: false},
	}
	records := map[string]plugintrust.Record{
		"dev.lithe.test.ready":    {PluginID: "dev.lithe.test.ready", Version: "1.0.0", Source: plugintrust.Marketplace, MarketplaceIndexURL: source},
		"dev.lithe.test.disabled": {PluginID: "dev.lithe.test.disabled", Version: "1.0.0", Source: plugintrust.Marketplace, MarketplaceIndexURL: source},
	}
	makePlugin := func(id string) core.MarketplacePlugin {
		return core.MarketplacePlugin{ID: id, Availability: core.MarketplaceAvailability{Status: "available", Version: "2.0.0"},
			Versions: []core.MarketplaceVersion{{Version: "2.0.0"}, {Version: "1.0.0"}}}
	}
	snapshot := marketplace.Snapshot{Source: core.MarketplaceSource{IndexURL: source},
		Index: core.MarketplaceIndex{Plugins: []core.MarketplacePlugin{makePlugin("dev.lithe.test.ready"), makePlugin("dev.lithe.test.disabled")}}}
	if got := autoUpdateCandidates(entries, records, snapshot); len(got) != 1 || got[0].ID != "dev.lithe.test.ready" {
		t.Fatalf("candidates = %+v", got)
	}
	snapshot.Source.IndexURL = "https://other.example.test/index.json"
	if got := autoUpdateCandidates(entries, records, snapshot); len(got) != 0 {
		t.Fatalf("foreign source selected: %+v", got)
	}
	snapshot.Source.IndexURL = source
	previous := records["dev.lithe.test.ready"]
	previous.MarketplaceIndexURL = ""
	records[previous.PluginID] = previous
	if got := autoUpdateCandidates(entries, records, snapshot); len(got) != 0 {
		t.Fatalf("unknown provenance selected: %+v", got)
	}
}

// A plugin from one approved index must not cause requests to other sources.
func TestApprovedPluginAutoSourceOnlyMatchesSavedOrigins(t *testing.T) {
	records := map[string]plugintrust.Record{
		"dev.lithe.test.one": {MarketplaceIndexURL: "https://example.test/one.json"},
	}
	if !approvedPluginAutoSource("https://example.test/one.json", records) {
		t.Fatal("a previously approved index should be eligible")
	}
	for _, url := range []string{"", "https://example.test/two.json", "http://example.test/one.json"} {
		if approvedPluginAutoSource(url, records) {
			t.Fatalf("source %q is not previously approved", url)
		}
	}
}
