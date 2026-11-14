package pluginmanager

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// newManager returns a manager over an empty plugin root.
func newManager(t *testing.T) (*Manager, *plugintrust.Store, *pluginstate.Store, string) {
	t.Helper()
	approvals := plugintrust.New(store.At(t.TempDir()))
	state := pluginstate.New(store.At(t.TempDir()))
	root := t.TempDir()
	return New(core.NewClient(), root, approvals, state), approvals, state, root
}

// uninstall removes plugin id; nothing of it runs in these tests.
func uninstall(manager *Manager, id string) error {
	_, err := manager.Apply(context.Background(), core.PluginUninstall, id, nil)
	return err
}

// enabled reports whether plugin id is installed and enabled.
func enabled(t *testing.T, manager *Manager, id string) bool {
	t.Helper()
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	for _, entry := range entries {
		if entry.Installed.ID == id {
			return entry.Enabled
		}
	}
	return false
}

// recorded reports whether the user's choice for plugin id is stored.
func recorded(t *testing.T, state *pluginstate.Store, id string) bool {
	t.Helper()
	entries, err := state.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, entry := range entries {
		if entry.PluginID == id {
			return true
		}
	}
	return false
}

// install puts one plugin version into the root.
func install(t *testing.T, root, id, version string) pluginpkg.Installed {
	t.Helper()
	return installManifest(t, root, id, version, "{}")
}

// installServing installs one plugin version whose manifest declares a language
// server for each of languages.
func installServing(t *testing.T, root, id, version string, languages ...string) pluginpkg.Installed {
	t.Helper()
	servers := make([]map[string]string, len(languages))
	for i, language := range languages {
		servers[i] = map[string]string{"languageID": language}
	}
	manifest, err := json.Marshal(map[string]any{"languageServers": servers})
	if err != nil {
		t.Fatal(err)
	}
	return installManifest(t, root, id, version, string(manifest))
}

// installManifest installs one plugin version that carries manifest.
func installManifest(t *testing.T, root, id, version, manifest string) pluginpkg.Installed {
	t.Helper()
	staging, err := pluginpkg.NewStaging(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	installed, err := pluginpkg.Install(root, id, version, staging)
	if err != nil {
		t.Fatal(err)
	}
	return installed
}

// approve records an approval for one plugin version.
func approve(t *testing.T, approvals *plugintrust.Store, id, version string) {
	t.Helper()
	record := plugintrust.RecordFor(id, version, plugintrust.Request{Source: plugintrust.Marketplace})
	if err := approvals.Approve(record); err != nil {
		t.Fatal(err)
	}
}

func TestInstalledReportsVersionsAndEnablement(t *testing.T) {
	manager, _, state, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "example", "1.1.0")
	install(t, root, "other", "2.0.0")
	if err := state.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("entries = %+v", entries)
	}
	for _, entry := range entries {
		if entry.Installed.ID == "example" && !entry.Enabled {
			t.Fatalf("example is reported disabled: %+v", entry)
		}
		if entry.Installed.ID == "other" && entry.Enabled {
			t.Fatalf("other is reported enabled: %+v", entry)
		}
	}
}

func TestInstalledIsEmptyWithoutRoot(t *testing.T) {
	manager, _, _, _ := newManager(t)
	entries, err := manager.Installed()
	if err != nil {
		t.Fatalf("installed: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("entries = %+v", entries)
	}
}

func TestUninstallRemovesPackageAndApproval(t *testing.T) {
	manager, approvals, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	approve(t, approvals, "example", "1.0.0")
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the package survived: %v", err)
	}
	if _, found, err := approvals.Record("example", "1.0.0"); err != nil || found {
		t.Fatalf("the approval survived: found = %v, err = %v", found, err)
	}
}

func TestUninstallForgetsEnablement(t *testing.T) {
	manager, _, state, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if recorded(t, state, "example") {
		t.Fatal("the enablement choice survived the uninstall")
	}
}

func TestUninstallRemovesEveryVersion(t *testing.T) {
	manager, approvals, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "example", "1.1.0")
	approve(t, approvals, "example", "1.0.0")
	approve(t, approvals, "example", "1.1.0")
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	// Installing leaves the earlier version on disk, and the plugin page shows one
	// row per plugin, so removing only the newest would keep the plugin installed.
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a version survived: %v", err)
	}
	for _, version := range []string{"1.0.0", "1.1.0"} {
		if _, found, err := approvals.Record("example", version); err != nil || found {
			t.Fatalf("the approval of %s survived: found = %v, err = %v", version, found, err)
		}
	}
}

func TestUninstallRefusesAnUnknownPlugin(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := uninstall(manager, "example"); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledRefusesUnknownPlugin(t *testing.T) {
	manager, _, _, _ := newManager(t)
	if err := manager.SetEnabled("example", true); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestSetEnabledAndInstalledRoundTrip(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	if enabled(t, manager, "example") {
		t.Fatal("a plugin without a choice is enabled")
	}
	if err := manager.SetEnabled("example", true); err != nil {
		t.Fatalf("set enabled: %v", err)
	}
	if !enabled(t, manager, "example") {
		t.Fatal("the enabled plugin is reported disabled")
	}
	if err := manager.SetEnabled("example", false); err != nil {
		t.Fatalf("set disabled: %v", err)
	}
	if enabled(t, manager, "example") {
		t.Fatal("the disabled plugin is reported enabled")
	}
}

// Uninstalling removes what the plugin's programs wrote below the plugin root,
// so nothing of an uninstalled plugin stays on disk; the state of other plugins
// and the host's own files there are kept.
func TestUninstallRemovesThePluginState(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "example", "1.0.0")
	install(t, root, "other", "1.0.0")
	stateRoot := filepath.Join(root, pluginpkg.StateDirectory)
	for _, file := range []string{
		filepath.Join("example", "1.0.0", "jdk-sources", "String.java"),
		filepath.Join("example", "pages", "workspaces", "w", "page.json"),
		filepath.Join("other", "1.0.0", "cache"),
		"host-secret",
	} {
		path := filepath.Join(stateRoot, file)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := uninstall(manager, "example"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the plugin's state survived: %v", err)
	}
	for _, kept := range []string{filepath.Join("other", "1.0.0", "cache"), "host-secret"} {
		if _, err := os.Stat(filepath.Join(stateRoot, kept)); err != nil {
			t.Fatalf("%s was removed with the plugin: %v", kept, err)
		}
	}
}

// Confirming an installation enables a plugin the user made no choice for, and
// keeps a choice the user made, such as disabling it before an update.
func TestEnableInstalledKeepsAnExplicitChoice(t *testing.T) {
	manager, _, _, root := newManager(t)
	install(t, root, "fresh", "1.0.0")
	install(t, root, "disabled", "1.0.0")
	if err := manager.SetEnabled("disabled", false); err != nil {
		t.Fatal(err)
	}
	install(t, root, "disabled", "1.1.0")
	for _, c := range []struct {
		id   string
		want bool
	}{{"fresh", true}, {"disabled", false}} {
		if _, err := manager.EnableInstalled(c.id); err != nil {
			t.Fatalf("enable %s: %v", c.id, err)
		}
		if got := enabled(t, manager, c.id); got != c.want {
			t.Fatalf("%s: enabled = %v, want %v", c.id, got, c.want)
		}
	}
	if _, err := manager.EnableInstalled("absent"); !errors.Is(err, ErrUnknownPlugin) {
		t.Fatalf("enabling a plugin that is not installed: %v", err)
	}
	// After an uninstall the choice is forgotten, so installing again enables it.
	if err := uninstall(manager, "disabled"); err != nil {
		t.Fatal(err)
	}
	install(t, root, "disabled", "1.1.0")
	if outcome, err := manager.EnableInstalled("disabled"); err != nil || !outcome.Changed {
		t.Fatalf("reinstall after uninstall: changed = %v, err = %v", outcome.Changed, err)
	}
}

// Enabling a plugin turns off every enabled plugin that serves one of its
// languages, records that, and reports it so the caller stops their programs;
// plugins that serve other languages, or none, stay enabled.
func TestEnableTurnsOffPluginsServingTheSameLanguage(t *testing.T) {
	manager, _, state, root := newManager(t)
	installServing(t, root, "complete", "1.2.0", "java", "jsp")
	installServing(t, root, "lightweight", "0.0.2", "java")
	installServing(t, root, "unrelated", "0.1.0", "go")
	install(t, root, "plain", "1.0.0")
	for _, id := range []string{"lightweight", "unrelated", "plain"} {
		if err := manager.SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
	}
	displaced, err := manager.Enable("complete")
	if err != nil {
		t.Fatal(err)
	}
	want := []Displaced{{PluginID: "lightweight", LanguageIDs: []string{"java"}}}
	if !reflect.DeepEqual(displaced, want) {
		t.Fatalf("displaced = %+v, want %+v", displaced, want)
	}
	for id, want := range map[string]bool{"complete": true, "lightweight": false, "unrelated": true, "plain": true} {
		if got := enabled(t, manager, id); got != want {
			t.Fatalf("%s: enabled = %v, want %v", id, got, want)
		}
	}
	choices, err := state.List()
	if err != nil {
		t.Fatal(err)
	}
	for _, choice := range choices {
		if choice.PluginID == "lightweight" && choice.Enabled {
			t.Fatal("the displaced plugin's choice is still enabled")
		}
	}
}

// Confirming the installation of a plugin that serves a language an enabled plugin
// serves turns that plugin off.
func TestEnableInstalledTurnsOffPluginsServingTheSameLanguage(t *testing.T) {
	manager, _, _, root := newManager(t)
	installServing(t, root, "lightweight", "0.0.2", "java")
	if err := manager.SetEnabled("lightweight", true); err != nil {
		t.Fatal(err)
	}
	installServing(t, root, "complete", "1.2.0", "java")
	outcome, err := manager.EnableInstalled("complete")
	if err != nil {
		t.Fatal(err)
	}
	want := Outcome{Changed: true, Displaced: []Displaced{{PluginID: "lightweight", LanguageIDs: []string{"java"}}}}
	if !reflect.DeepEqual(outcome, want) {
		t.Fatalf("outcome = %+v, want %+v", outcome, want)
	}
	if enabled(t, manager, "lightweight") {
		t.Fatal("the installed plugin left the other Java server enabled")
	}
}

// Choices made before the rule can enable two plugins serving one language; only
// the first by ID reports enabled, and disabling it lets the other take over.
func TestEarlierChoicesEnableOnePluginPerLanguage(t *testing.T) {
	manager, _, state, root := newManager(t)
	installServing(t, root, "complete", "1.2.0", "java")
	installServing(t, root, "lightweight", "0.0.2", "java")
	for _, id := range []string{"complete", "lightweight"} {
		if err := state.SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
	}
	if !enabled(t, manager, "complete") || enabled(t, manager, "lightweight") {
		t.Fatal("two plugins serving Java are both enabled")
	}
	if err := manager.SetEnabled("complete", false); err != nil {
		t.Fatal(err)
	}
	if !enabled(t, manager, "lightweight") {
		t.Fatal("disabling the plugin that served Java did not let the other take over")
	}
}

// A manifest that cannot be decoded declares no language server, so it neither
// displaces nor is displaced, and it does not break the other plugins' plan.
func TestUnreadableManifestServesNothing(t *testing.T) {
	manager, _, _, root := newManager(t)
	installManifest(t, root, "broken", "1.0.0", "{")
	installServing(t, root, "complete", "1.2.0", "java")
	if err := manager.SetEnabled("broken", true); err != nil {
		t.Fatal(err)
	}
	displaced, err := manager.Enable("complete")
	if err != nil || len(displaced) != 0 {
		t.Fatalf("displaced = %+v, err = %v", displaced, err)
	}
	if !enabled(t, manager, "broken") || !enabled(t, manager, "complete") {
		t.Fatal("an unreadable manifest changed another plugin's enablement")
	}
}
