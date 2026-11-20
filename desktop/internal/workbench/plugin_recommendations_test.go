package workbench

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func recommendationTestStore(t *testing.T) *store.Store {
	t.Helper()
	prefs := store.At(t.TempDir())
	// An explicit theme avoids calling app.SystemAppearance() without an active NSApplication loop.
	if err := prefs.Save(settingsFile, settings{Theme: themeDark}); err != nil {
		t.Fatal(err)
	}
	return prefs
}

func syntheticRecommendationCatalog(t *testing.T, recommendationsJSON string) core.MarketplaceRecommendationCatalog {
	t.Helper()
	platform := marketplaceHostPlatform()
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	indexPayload, err := json.Marshal(map[string]any{
		"schemaVersion": 0,
		"plugins": []map[string]any{
			{
				"id":          "io.example.demo-lang",
				"name":        "Demo Lang",
				"author":      "Example Authors",
				"repository":  "https://github.com/example/demo-lang",
				"description": "Synthetic language support fixture for workspace recommendations.",
				"tags":        []string{"language"},
				"license":     "MIT",
				"versions": []map[string]any{
					{
						"version":          "1.0.0",
						"pluginAPIVersion": 0,
						"requires":         map[string]any{"languages": 0},
						"releaseDate":      "2026-10-01",
						"downloads": []map[string]any{
							{
								"platforms":   []string{platform},
								"downloadURL": "https://github.com/example/demo-lang/releases/download/v1.0.0/demo-lang.zip",
								"sha256":      shaA,
							},
						},
					},
				},
			},
			{
				"id":          "io.example.demo-build",
				"name":        "Demo Build",
				"author":      "Example Authors",
				"repository":  "https://github.com/example/demo-build",
				"description": "Synthetic build system fixture for workspace recommendations.",
				"tags":        []string{"build"},
				"license":     "MIT",
				"versions": []map[string]any{
					{
						"version":          "1.0.0",
						"pluginAPIVersion": 0,
						"requires":         map[string]any{"languages": 0},
						"releaseDate":      "2026-10-01",
						"downloads": []map[string]any{
							{
								"platforms":   []string{platform},
								"downloadURL": "https://github.com/example/demo-build/releases/download/v1.0.0/demo-build.zip",
								"sha256":      shaB,
							},
						},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return core.MarketplaceRecommendationCatalog{
		Index:           indexPayload,
		SourceKind:      core.MarketplaceThirdParty,
		IndexURL:        "https://example.com/lithe-plugin-index.json",
		Recommendations: []byte(recommendationsJSON),
	}
}

func performedAction(logger *actionFieldLog, action string) bool {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	return slices.Contains(logger.actions, action)
}

func TestPluginRecommendationsNotifyOpenSettingsAndDismiss(t *testing.T) {
	const recCatalog = `{
		"schemaVersion": 0,
		"recommendations": [
			{ "pluginID": "io.example.demo-lang", "markers": ["demo.toml"] }
		]
	}`
	workspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(workspace, "demo.toml"), []byte("[project]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	logger := &actionFieldLog{}
	prefs := recommendationTestStore(t)
	var fetches atomic.Int32
	catalog := syntheticRecommendationCatalog(t, recCatalog)
	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     prefs,
		Logs:      logger,
		Languages: []string{"en-US"},
		PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
			fetches.Add(1)
			return []core.MarketplaceRecommendationCatalog{catalog}, nil
		},
	})
	h.open(workspace)

	wantMsg := i18n.SharedFormat(h.app.language(), "desktop.marketplace.recommendedPlugins", map[string]string{
		"plugins": "Demo Lang",
	})
	awaitStateWithin(t, h, 5*time.Second, "plugin recommendation notification", func() bool {
		return h.app.notice == wantMsg && len(h.app.notifications.list) == 1
	})
	if fetches.Load() != 1 {
		t.Fatalf("fetches = %d, want 1", fetches.Load())
	}

	// Primary action opens plugin settings under surfaceNotification.
	actionLabel := i18n.Shared(h.app.language(), "desktop.marketplace.recommendedAction")
	if n := h.pageControls(actionLabel); n != 1 {
		t.Fatalf("toast primary button count = %d, want 1", n)
	}
	h.clickNamed(actionLabel)
	h.settle()
	if !performedAction(logger, "settings.open") {
		t.Fatal("expected settings.open performed action on primary notification click")
	}

	// Secondary action from notification drawer persists dismissal across restarts.
	for _, entry := range h.app.notifications.list {
		h.app.overlay.toaster.Close(entry.toast)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickNamed("Notifications, 1 unread")
	h.settle()

	dismissLabel := i18n.Shared(h.app.language(), "desktop.marketplace.recommendedDismiss")
	if n := h.pageControls(dismissLabel); n != 1 {
		t.Fatalf("drawer dismiss button count = %d, want 1", n)
	}
	h.clickNamed(dismissLabel)
	h.settle()

	var saved settings
	if ok, err := prefs.Load(settingsFile, &saved); err != nil || !ok {
		t.Fatalf("Load settings = (%v, %v)", ok, err)
	}
	if !slices.Equal(saved.DismissedPluginRecommendations, []string{"io.example.demo-lang"}) {
		t.Fatalf("saved.DismissedPluginRecommendations = %v", saved.DismissedPluginRecommendations)
	}

	// Reopening in a new window with the same Store settles all background tasks and verifies
	// the dismissed plugin is not notified again.
	var fetches2 atomic.Int32
	h2 := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     prefs,
		Languages: []string{"en-US"},
		PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
			fetches2.Add(1)
			return []core.MarketplaceRecommendationCatalog{catalog}, nil
		},
	})
	h2.open(workspace)
	h2.settle()
	if fetches2.Load() != 1 || len(h2.app.notifications.list) != 0 {
		t.Fatalf("reopened dismissed workspace fetches=%d notices=%d, want 1, 0", fetches2.Load(), len(h2.app.notifications.list))
	}
}

func TestPluginRecommendationsCombinesMultipleMatches(t *testing.T) {
	const recCatalog = `{
		"schemaVersion": 0,
		"recommendations": [
			{ "pluginID": "io.example.demo-build", "markers": ["demo.toml"] },
			{ "pluginID": "io.example.demo-lang", "extensions": ["demo"] }
		]
	}`
	workspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(workspace, "demo.toml"), []byte("[build]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(workspace, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "src", "main.demo"), []byte("fn main() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	logger := &actionFieldLog{}
	catalog := syntheticRecommendationCatalog(t, recCatalog)
	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     recommendationTestStore(t),
		Logs:      logger,
		Languages: []string{"en-US"},
		PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
			return []core.MarketplaceRecommendationCatalog{catalog}, nil
		},
	})
	h.open(workspace)

	wantMsg := i18n.SharedFormat(h.app.language(), "desktop.marketplace.recommendedPlugins", map[string]string{
		"plugins": "Demo Build, Demo Lang",
	})
	awaitStateWithin(t, h, 5*time.Second, "combined recommendation notification", func() bool {
		return h.app.notice == wantMsg && len(h.app.notifications.list) == 1
	})

	h.clickNamed(i18n.Shared(h.app.language(), "desktop.marketplace.recommendedAction"))
	h.settle()
	if !performedAction(logger, "settings.open") {
		t.Fatal("expected settings.open on multiple-plugin primary action")
	}
}

func TestPluginRecommendationsEmptyOr404StaySilent(t *testing.T) {
	workspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(workspace, "README.md"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     recommendationTestStore(t),
		Languages: []string{"en-US"},
		PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
			return nil, nil
		},
	})
	h.open(workspace)
	h.settle()
	if len(h.app.notifications.list) != 0 || h.app.notice != "" {
		t.Fatalf("unexpected activity: notices=%d notice=%q", len(h.app.notifications.list), h.app.notice)
	}
}

func TestPluginRecommendationsExcludeInstalledOrCoveredByPlugins(t *testing.T) {
	const recCatalog = `{
		"schemaVersion": 0,
		"recommendations": [
			{
				"pluginID": "io.example.demo-lang",
				"markers": ["demo.toml"],
				"coveredBy": ["io.github.example.output-links"]
			}
		]
	}`
	workspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(workspace, "demo.toml"), []byte("[project]\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := newHarnessWithOptions(t, Options{
		Kernel:    &testKernel{Client: core.NewClient()},
		Store:     recommendationTestStore(t),
		Languages: []string{"en-US"},
		PluginRecommendationFetcher: func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error) {
			return []core.MarketplaceRecommendationCatalog{syntheticRecommendationCatalog(t, recCatalog)}, nil
		},
	})
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service

	// Install the covering plugin io.github.example.output-links into service.Root.
	archivePath, digest := writeTestPluginZip(t, t.TempDir(), "io.github.example.output-links", installablePluginManifest)
	plan, err := h.app.preparePlugin(context.Background(), plugininstall.Request{
		ArchivePath:         archivePath,
		Root:                service.Root,
		Source:              plugintrust.Marketplace,
		ArchiveSHA256:       digest,
		MarketplaceIndexURL: "https://example.com/lithe-plugin-index.json",
		ExpectedID:          "io.github.example.output-links",
		ExpectedVersion:     "1.0.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Installer.Discard(plan) })
	if _, err := service.Installer.Commit(plan); err != nil {
		t.Fatal(err)
	}

	h.open(workspace)
	h.settle()
	if len(h.app.notifications.list) != 0 {
		t.Fatalf("expected coveredBy plugin not to notify, got %d notices", len(h.app.notifications.list))
	}
}

func TestScanWorkspaceRecommendationFilesRespectsBoundsAndSkipsSymlinks(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{
		"a/b/c",        // depth 3: scanned
		"a/b/c/d",      // depth 4: skipped
		".git",         // ignored
		"node_modules", // ignored
	} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite := func(rel string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, rel), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("pom.xml")
	mustWrite("a/b/c/inside.java")
	mustWrite("a/b/c/d/too_deep.go")
	mustWrite(".git/HEAD")
	mustWrite("node_modules/ignored.go")

	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "escape.go"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "symlink-dir")); err != nil && !errors.Is(err, os.ErrPermission) {
		t.Fatal(err)
	}

	files, warnings, err := scanWorkspaceRecommendationFiles(context.Background(), root, 3, 4000)
	if err != nil || len(warnings) != 0 {
		t.Fatalf("scan = (%v, %v), want nil error/warnings", warnings, err)
	}
	if !slices.Contains(files, "pom.xml") || !slices.Contains(files, "a/b/c/inside.java") {
		t.Fatalf("missing expected files in %v", files)
	}
	for _, unexpected := range []string{"a/b/c/d/too_deep.go", ".git/HEAD", "node_modules/ignored.go", "symlink-dir/escape.go"} {
		if slices.Contains(files, unexpected) {
			t.Fatalf("unexpected file %q in %v", unexpected, files)
		}
	}

	// Enforce strict entry limit.
	manyRoot := t.TempDir()
	for i := range 25 {
		if err := os.WriteFile(filepath.Join(manyRoot, "file_"+string(rune('a'+i))+".txt"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	bounded, _, err := scanWorkspaceRecommendationFiles(context.Background(), manyRoot, 3, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(bounded) != 5 {
		t.Fatalf("bounded len = %d, want 5", len(bounded))
	}
}

func writeTestPluginZip(t *testing.T, dir, pluginID, manifest string) (string, string) {
	t.Helper()
	var payload bytes.Buffer
	writer := zip.NewWriter(&payload)
	entry, err := writer.Create(pluginID + "/plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(manifest)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	archiveBytes := payload.Bytes()
	sum := sha256.Sum256(archiveBytes)
	zipPath := filepath.Join(dir, "plugin.zip")
	if err := os.WriteFile(zipPath, archiveBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	return zipPath, hex.EncodeToString(sum[:])
}
