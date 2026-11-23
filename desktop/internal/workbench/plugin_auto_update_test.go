package workbench

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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

// A marketplace update uses the same verified archive and approval path as a
// manual install. The previous approved version remains on disk while the next
// version is selected, without any real plugin, network, or toolchain.
func TestPluginAutoUpdateStagesAnApprovedNewVersionUntilRestart(t *testing.T) {
	for _, scenario := range []string{"activate", "disabled before restart", "damaged package"} {
		t.Run(scenario, func(t *testing.T) { verifyPendingPluginUpdate(t, scenario) })
	}
}

func verifyPendingPluginUpdate(t *testing.T, scenario string) {
	t.Helper()
	const id = "io.github.example.output-links"
	const origin = "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json"
	const archiveURL = "https://plugins.example.test/auto-update.zip"

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service

	archiveBytes := func(version string) ([]byte, string) {
		t.Helper()
		manifest := strings.Replace(installablePluginManifest, `"version": "1.0.0"`, `"version": "`+version+`"`, 1)
		if !strings.Contains(manifest, `"version": "`+version+`"`) {
			t.Fatalf("fixture version %q was not applied", version)
		}
		var payload bytes.Buffer
		writer := zip.NewWriter(&payload)
		entry, err := writer.Create(id + "/plugin.json")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(manifest)); err != nil {
			t.Fatal(err)
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(payload.Bytes())
		return payload.Bytes(), hex.EncodeToString(hash[:])
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	firstBytes, firstDigest := archiveBytes("1.0.0")
	firstPath := filepath.Join(t.TempDir(), "first.zip")
	if err := os.WriteFile(firstPath, firstBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	first, err := h.app.preparePlugin(ctx, plugininstall.Request{
		ArchivePath: firstPath, Root: service.Root, Source: plugintrust.Marketplace,
		ArchiveSHA256: firstDigest, MarketplaceIndexURL: origin,
		ExpectedID: id, ExpectedVersion: "1.0.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Installer.Discard(first) })
	// The fixture models the user's initial, explicitly approved marketplace install.
	if _, err := service.Installer.Commit(first); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Manager.EnableInstalled(id); err != nil {
		t.Fatal(err)
	}
	previous, found, err := service.Manager.Approval(id, "1.0.0")
	if err != nil || !found || previous.MarketplaceIndexURL != origin {
		t.Fatalf("initial approved source = %+v, found = %v, error = %v", previous, found, err)
	}

	nextBytes, nextDigest := archiveBytes("2.0.0")
	requests := 0
	client := &http.Client{Transport: pluginArchiveTransport(func(request *http.Request) (*http.Response, error) {
		requests++
		if request.URL.String() != archiveURL {
			t.Errorf("archive request = %q, want %q", request.URL, archiveURL)
		}
		return &http.Response{
			StatusCode: http.StatusOK, Header: make(http.Header),
			Body:          io.NopCloser(bytes.NewReader(nextBytes)),
			ContentLength: int64(len(nextBytes)), Request: request,
		}, nil
	})}
	download := marketplace.NewArchiveDownloader(client)
	offer := core.MarketplacePlugin{
		ID: id, MarketplaceIndexURL: origin,
		Availability: core.MarketplaceAvailability{
			Status: "available", Version: "2.0.0", SHA256: nextDigest, DownloadURL: archiveURL,
		},
	}
	applied, err := h.app.applyPluginAutoUpdate(ctx, download, offer, previous)
	if err != nil || !applied || requests != 1 {
		t.Fatalf("auto-updated = %v, request count = %d, error = %v", applied, requests, err)
	}
	versions, err := pluginpkg.List(service.Root)
	if err != nil || len(versions) != 1 || versions[0].Version != "1.0.0" {
		t.Fatalf("installed versions before restart = %+v, error = %v", versions, err)
	}
	if _, approved, err := service.Manager.Approval(id, "2.0.0"); err != nil || approved {
		t.Fatalf("pending approval became active before restart: %v, %v", approved, err)
	}
	if scenario == "disabled before restart" {
		if _, err := service.Manager.Apply(ctx, core.PluginDisable, id, nil); err != nil {
			t.Fatal(err)
		}
	}
	if scenario == "damaged package" {
		pending := filepath.Join(service.Root, ".pending-updates", id, "package", pluginpkg.ManifestFile)
		if err := os.WriteFile(pending, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	activationErr := service.ActivatePendingUpdates(ctx)
	if scenario == "damaged package" {
		if !errors.Is(activationErr, plugininstall.ErrArchiveDigest) {
			t.Fatalf("expected a digest rejection, got %v", activationErr)
		}
	} else if activationErr != nil {
		t.Fatal(activationErr)
	}
	versions, err = pluginpkg.List(service.Root)
	if scenario != "activate" {
		if err != nil || len(versions) != 1 || versions[0].Version != "1.0.0" {
			t.Fatalf("ineligible plugin was updated: %+v, %v", versions, err)
		}
		pending, err := service.Installer.HasPending(service.Root, id)
		if err != nil || pending {
			t.Fatalf("ineligible plugin still has pending update: %v, %v", pending, err)
		}
		return
	}
	if err != nil || len(versions) != 2 {
		t.Fatalf("retained installed versions after restart = %+v, error = %v", versions, err)
	}
	selected, err := service.CurrentInstalled(ctx)
	if err != nil || len(selected) != 1 || selected[0].Installed.Version != "2.0.0" {
		t.Fatalf("selected plugin version = %+v, error = %v", selected, err)
	}
	record, approved, err := service.Manager.Approval(id, "2.0.0")
	if err != nil || !approved || record.MarketplaceIndexURL != origin {
		t.Fatalf("new approved source = %+v, found = %v, error = %v", record, approved, err)
	}
}
