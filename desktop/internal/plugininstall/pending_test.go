package plugininstall

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

func TestStageUpdateLeavesInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	root, err := pluginpkg.DefaultRoot()
	if err != nil {
		t.Fatal(err)
	}
	staging, err := pluginpkg.NewStaging(root)
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, staging)
	const id = "dev.lithe.test.pending"
	const source = "https://example.test/lithe-plugin-index.json"
	if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), []byte(`{"id":"dev.lithe.test.pending","version":"2.0.0"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	service := &Service{}
	previous := plugintrust.Record{PluginID: id, Version: "1.0.0", Source: plugintrust.Marketplace, MarketplaceIndexURL: source}
	if err := service.StageAutomatic(Plan{Root: root, Staging: staging, ID: id, Version: "2.0.0",
		Source: plugintrust.Marketplace, MarketplaceIndexURL: source}, previous); err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, filepath.Join(root, pendingDirectory, id))
	if err := service.DiscardPending(root, id); err != nil {
		t.Fatal(err)
	}
}
