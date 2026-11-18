package plugintrust

import (
	"encoding/json"
	"testing"
)

func TestMayAutoUpdateRequiresSameApprovedSourceAndGrants(t *testing.T) {
	old := Record{
		PluginID: "dev.lithe.test.example", Version: "1.0.0",
		Source: Marketplace, MarketplaceIndexURL: "https://example.test/index.json",
		Permissions:      []string{"language", "editor"},
		ApprovedPrograms: []json.RawMessage{json.RawMessage(`{"id":"daemon","program":"bin/daemon"}`)},
	}
	next := Review{
		Permissions: []string{"editor", "language"},
		Programs:    []json.RawMessage{json.RawMessage(`{"program":"bin/daemon","id":"daemon"}`)},
	}
	if !MayAutoUpdate(old, true, old.MarketplaceIndexURL, next) {
		t.Fatal("identical previously approved grants should allow an opt-in auto-update")
	}
	check := func(label string, old Record, found bool, url string, next Review) {
		t.Helper()
		if MayAutoUpdate(old, found, url, next) {
			t.Fatalf("%s incorrectly allowed an automatic upgrade", label)
		}
	}
	check("missing approval", old, false, old.MarketplaceIndexURL, next)
	check("different source", old, true, "https://other.example/index.json", next)
	legacy := old
	legacy.MarketplaceIndexURL = ""
	check("legacy source unknown", legacy, true, old.MarketplaceIndexURL, next)
	disk := old
	disk.Source = Disk
	check("disk origin", disk, true, old.MarketplaceIndexURL, next)
	newPermission := next
	newPermission.Permissions = []string{"editor", "language", "terminal"}
	check("new permission", old, true, old.MarketplaceIndexURL, newPermission)
	newProgram := next
	newProgram.Programs = []json.RawMessage{json.RawMessage(`{"id":"daemon","program":"bin/other"}`)}
	check("program changed", old, true, old.MarketplaceIndexURL, newProgram)
	invalid := next
	invalid.Programs = []json.RawMessage{json.RawMessage(`{`)}
	check("invalid declaration", old, true, old.MarketplaceIndexURL, invalid)
}
