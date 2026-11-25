package pluginservice

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

type snapshotKernel struct {
	*fakeKernel
	selections int
	relayCalls int
	onSelect   func()
}

func (k *snapshotKernel) SelectInstalledPluginVersions(ctx context.Context, facts []core.InstalledPluginFact, includeDisabled bool) (core.InstalledPluginSelection, error) {
	k.selections++
	selection, err := k.fakeKernel.SelectInstalledPluginVersions(ctx, facts, includeDisabled)
	if k.onSelect != nil {
		k.onSelect()
	}
	return selection, err
}

func (k *snapshotKernel) ConfigureFunctionRelay(ctx context.Context, plugins []core.RelayPlugin, contexts []core.RelayContext) error {
	k.relayCalls++
	return k.fakeKernel.ConfigureFunctionRelay(ctx, plugins, contexts)
}

func snapshotEntry(t *testing.T, id, version, manifest string) pluginmanager.Entry {
	t.Helper()
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	return pluginmanager.Entry{Installed: pluginpkg.Installed{ID: id, Version: version, Path: directory}, Enabled: true}
}

// This fictional declaration exercises the installed-file readers. Install-time
// schema validation is covered separately by the Core contract tests.
const snapshotManifest = `{
	"id":"dev.lithe.test.snapshot","version":"1.0.0","displayName":"Snapshot",
	"languages":[{"id":"snapshot","fileExtensions":[".snapshot"]}],
	"languageServers":[{"languageID":"snapshot"}],
	"buildSystems":[{"id":"snapshot-build","displayName":"Snapshot Build"}],
	"vcsProviders":[{"id":"snapshot-vcs","displayName":"Snapshot VCS"}],
	"debugAdapters":[{"id":"snapshot-debug","displayName":"Snapshot Debug","launch":{"transport":"stdio","process":{"launch":{"kind":"packaged","path":"fixture"}}}}],
	"ui":{"toolWindows":[{"id":"snapshot-window","title":"Before","text":"Snapshot"}],"commands":[{"id":"snapshot-command","title":"Before","toolWindowID":"snapshot-window"}]},
	"outputLinkMatchers":[{"id":"snapshot-link","pattern":"snapshot"}]
}`

func TestInstalledToolWindowKeepsPackageIconDeclaration(t *testing.T) {
	manifest := strings.Replace(snapshotManifest, `"title":"Before","text":"Snapshot"`,
		`"title":"Before","text":"Snapshot","icon":{"path":"icons/light.svg","darkPath":"icons/dark.svg","mode":"original"}`, 1)
	entry := snapshotEntry(t, "dev.lithe.test.snapshot", "1.0.0", manifest)
	service := &Service{kernel: &fakeKernel{}}
	windows, err := service.ToolWindows(context.Background(), []pluginmanager.Entry{entry})
	want := pluginicons.Declaration{Path: "icons/light.svg", DarkPath: "icons/dark.svg", Mode: "original"}
	if err != nil || len(windows) != 1 {
		t.Fatalf("tool windows = %+v, %v", windows, err)
	}
	if windows[0].Icon != want || windows[0].IconHost != "" || windows[0].Package != entry.Installed.Path {
		t.Fatalf("package icon declaration = %+v, want %+v in its installed package", windows[0], want)
	}
}

func TestInstalledSnapshotKeepsOneManifestAcrossConsumers(t *testing.T) {
	ctx := context.Background()
	kernel := &snapshotKernel{fakeKernel: &fakeKernel{}}
	service := &Service{kernel: kernel}
	entry := snapshotEntry(t, "dev.lithe.test.snapshot", "1.0.0", snapshotManifest)
	snapshot, err := service.ReadInstalled(ctx, []pluginmanager.Entry{entry})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile)
	if err := os.WriteFile(path, []byte(`{"ui":{"toolWindows":[{"id":"changed","title":"After"}]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	languages, err := service.LoadLanguagesFromSnapshot(ctx, snapshot)
	if err != nil || len(languages) != 1 || languages[0].ID != "snapshot" {
		t.Fatalf("languages = %+v, %v", languages, err)
	}
	windows, err := snapshot.ToolWindows()
	if err != nil || len(windows) != 1 || windows[0].Title != "Before" {
		t.Fatalf("windows = %+v, %v", windows, err)
	}
	commands, err := snapshot.ToolCommands()
	if err != nil || len(commands) != 1 || commands[0].Title != "Before" {
		t.Fatalf("commands = %+v, %v", commands, err)
	}
	builds, err := snapshot.BuildPlugins()
	if err != nil || len(builds) != 1 || builds[0].Systems["snapshot-build"].DisplayName != "Snapshot Build" {
		t.Fatalf("builds = %+v, %v", builds, err)
	}
	vcs, err := snapshot.VcsPlugins()
	if err != nil || len(vcs) != 1 || vcs[0].Providers[0].ID != "snapshot-vcs" {
		t.Fatalf("VCS = %+v, %v", vcs, err)
	}
	debug, err := snapshot.DebugPlugins()
	if err != nil || len(debug) != 1 || debug[0].Adapters[0].ID != "snapshot-debug" {
		t.Fatalf("debug = %+v, %v", debug, err)
	}
	links, err := snapshot.OutputLinkSources()
	if err != nil || len(links) != 1 || links[0].PluginID != entry.Installed.ID {
		t.Fatalf("links = %+v, %v", links, err)
	}
	sources, err := snapshot.SearchLanguageSources()
	if err != nil || len(sources) != 1 || sources[0].LanguageID != "snapshot" {
		t.Fatalf("search languages = %+v, %v", sources, err)
	}
	tools := snapshot.ToolchainPlugins()
	if len(tools) != 1 || !bytes.Equal(tools[0].Manifest, []byte(snapshotManifest)) {
		t.Fatalf("toolchains = %+v", tools)
	}
	generators := snapshot.GeneratorPlugins()
	if len(generators) != 1 || !bytes.Equal(generators[0].Manifest, []byte(snapshotManifest)) {
		t.Fatalf("generators = %+v", generators)
	}
	if kernel.selections != 1 {
		t.Fatalf("selections = %d, want one for every consumer", kernel.selections)
	}

	// A second operation takes fresh bytes; retaining the first snapshot never
	// turns the service into a cache across installation or enablement changes.
	next, err := service.ReadInstalled(ctx, []pluginmanager.Entry{entry})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	windows, err = next.ToolWindows()
	if err != nil || len(windows) != 1 || windows[0].Title != "After" || kernel.selections != 2 {
		t.Fatalf("fresh snapshot = %+v, %v, selections=%d", windows, err, kernel.selections)
	}
}

func TestInstalledSnapshotPreservesPartialResultsAndReadErrors(t *testing.T) {
	ctx := context.Background()
	service := &Service{kernel: &snapshotKernel{fakeKernel: &fakeKernel{}}}
	healthy := snapshotEntry(t, "dev.lithe.test.healthy", "1.0.0", snapshotManifest)
	missing := snapshotEntry(t, "dev.lithe.test.missing", "1.0.0", snapshotManifest)
	if err := os.Remove(filepath.Join(missing.Installed.Path, pluginpkg.ManifestFile)); err != nil {
		t.Fatal(err)
	}
	badVersion := snapshotEntry(t, "dev.lithe.test.bad-version", "invalid", snapshotManifest)
	snapshot, err := service.ReadInstalled(ctx, []pluginmanager.Entry{missing, healthy, badVersion})
	if !errors.Is(err, os.ErrNotExist) || !errors.Is(err, ErrPackageRead) || !strings.Contains(err.Error(), badVersion.Installed.ID) {
		t.Fatalf("missing joined read/selection diagnostics: %v", err)
	}
	if strings.Count(err.Error(), missing.Installed.ID) != 1 {
		t.Fatalf("read error repeated: %v", err)
	}
	windows, err := snapshot.ToolWindows()
	if err != nil || len(windows) != 1 || windows[0].PluginID != healthy.Installed.ID {
		t.Fatalf("healthy contribution = %+v, %v", windows, err)
	}
	brokenJSON := snapshotEntry(t, "dev.lithe.test.broken-json", "1.0.0", `{`)
	snapshot, err = service.ReadInstalled(ctx, []pluginmanager.Entry{brokenJSON, healthy})
	if err != nil {
		t.Fatal(err)
	}
	windows, err = snapshot.ToolWindows()
	if err == nil || len(windows) != 1 || windows[0].PluginID != healthy.Installed.ID || !strings.Contains(err.Error(), brokenJSON.Installed.ID) {
		t.Fatalf("partial parse result = %+v, %v", windows, err)
	}
}

func TestInstalledSnapshotUsesCoreVersionAndEnablementSelection(t *testing.T) {
	ctx := context.Background()
	kernel := &snapshotKernel{fakeKernel: &fakeKernel{}}
	service := &Service{kernel: kernel}
	old := snapshotEntry(t, "dev.lithe.test.versioned", "1.0.0", `{"version":"1.0.0"}`)
	latest := snapshotEntry(t, old.Installed.ID, "2.0.0", `{"version":"2.0.0"}`)
	entries := []pluginmanager.Entry{old, latest}
	snapshot, err := service.ReadInstalled(ctx, entries)
	if err != nil || len(snapshot.ToolchainPlugins()) != 1 || snapshot.ToolchainPlugins()[0].Version != "2.0.0" {
		t.Fatalf("version selection = %+v, %v", snapshot.ToolchainPlugins(), err)
	}
	entries[0].Enabled, entries[1].Enabled = false, false
	snapshot, err = service.ReadInstalled(ctx, entries)
	if err != nil || len(snapshot.ToolchainPlugins()) != 0 {
		t.Fatalf("disabled plugins remain active: %+v, %v", snapshot.ToolchainPlugins(), err)
	}
	inventory, err := service.readInstalled(ctx, entries, true)
	if err != nil {
		t.Fatal(err)
	}
	generators := inventory.GeneratorPlugins()
	if len(generators) != 1 || generators[0].Enabled || generators[0].Version != "2.0.0" {
		t.Fatalf("generator inventory lost disabled newest version: %+v", generators)
	}
	if kernel.selections != 3 {
		t.Fatalf("selections = %d, want one per operation", kernel.selections)
	}
}

func TestInstalledSnapshotCancelsBeforeManifestIO(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	kernel := &snapshotKernel{fakeKernel: &fakeKernel{}, onSelect: cancel}
	service := &Service{kernel: kernel}
	entry := pluginmanager.Entry{Installed: pluginpkg.Installed{ID: "dev.lithe.test.cancelled", Version: "1.0.0", Path: t.TempDir()}, Enabled: true}
	snapshot, err := service.ReadInstalled(ctx, []pluginmanager.Entry{entry})
	if !errors.Is(err, context.Canceled) || errors.Is(err, os.ErrNotExist) || len(snapshot.ToolchainPlugins()) != 0 {
		t.Fatalf("cancelled read = %+v, %v", snapshot, err)
	}
	emptyCtx, cancelEmpty := context.WithCancel(context.Background())
	defer cancelEmpty()
	emptyKernel := &snapshotKernel{fakeKernel: &fakeKernel{}, onSelect: cancelEmpty}
	emptySnapshot, err := (&Service{kernel: emptyKernel}).ReadInstalled(emptyCtx, nil)
	if !errors.Is(err, context.Canceled) || len(emptySnapshot.ToolchainPlugins()) != 0 {
		t.Fatalf("cancelled empty read = %+v, %v", emptySnapshot, err)
	}
}

func TestSyncFunctionRelayGuardsCancellationAndNilKernel(t *testing.T) {
	kernel := &snapshotKernel{fakeKernel: &fakeKernel{}}
	contexts := newWorkspaceContexts(t.TempDir())
	service := &Service{kernel: kernel, Contexts: contexts}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := service.SyncFunctionRelay(ctx, nil); !errors.Is(err, context.Canceled) || kernel.relayCalls != 0 {
		t.Fatalf("cancelled SyncFunctionRelay = %v, relayCalls = %d", err, kernel.relayCalls)
	}
	if err := (&Service{Contexts: contexts}).SyncFunctionRelay(context.Background(), nil); !errors.Is(err, ErrAssembly) {
		t.Fatalf("nil kernel SyncFunctionRelay = %v, want ErrAssembly", err)
	}
}

func TestInstalledSnapshotKeepsTheManifestSizeLimit(t *testing.T) {
	entry := snapshotEntry(t, "dev.lithe.test.large", "1.0.0", `{}`)
	file, err := os.OpenFile(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	err = file.Truncate(MaxManifestBytes + 1)
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		t.Fatalf("prepare oversized manifest: %v, %v", err, closeErr)
	}
	service := &Service{kernel: &snapshotKernel{fakeKernel: &fakeKernel{}}}
	snapshot, err := service.ReadInstalled(context.Background(), []pluginmanager.Entry{entry})
	if !errors.Is(err, ErrPackageRead) || len(snapshot.ToolchainPlugins()) != 0 {
		t.Fatalf("oversized manifest = %+v, %v", snapshot, err)
	}
}
