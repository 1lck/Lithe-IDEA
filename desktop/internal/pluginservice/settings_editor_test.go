package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestInstalledSettingsEditorPublishesAndRejectsChangedOwners(t *testing.T) {
	for _, change := range []string{"save", "manifest", "upgrade", "uninstall", "directory", "workspace"} {
		t.Run(change, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
			if err != nil {
				t.Fatal(err)
			}
			var fixture struct {
				Manifest json.RawMessage `json:"manifest"`
			}
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatal(err)
			}
			preferences, plugins := t.TempDir(), t.TempDir()
			packageRoot := filepath.Join(plugins, "dev.example.settings", "1.0.0")
			writePackage := func(directory string, manifest []byte) {
				t.Helper()
				if err := os.MkdirAll(directory, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), manifest, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			writePackage(packageRoot, fixture.Manifest)
			kernel := &settingsPlanningKernel{fakeKernel: &fakeKernel{}, client: core.NewClient()}
			service, err := Open(kernel, store.At(preferences), plugins)
			if err != nil {
				t.Fatal(err)
			}
			catalog, err := service.SettingsCatalog(ctx)
			if err != nil || len(catalog) != 1 || catalog[0].ID != "dev.example.settings" {
				t.Fatalf("local catalog=%+v error=%v", catalog, err)
			}
			editor, err := service.LoadSettingsEditor(ctx, "dev.example.settings", "")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(preferences, "plugin-settings.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("load wrote preferences: %v", err)
			}
			var ownerCheck func() error
			switch change {
			case "manifest":
				writePackage(packageRoot, append(append([]byte(nil), fixture.Manifest...), '\n'))
			case "upgrade":
				writePackage(filepath.Join(plugins, "dev.example.settings", "1.1.0"), fixture.Manifest)
			case "uninstall":
				if err := os.RemoveAll(packageRoot); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Rename(packageRoot, packageRoot+"-retired"); err != nil {
					t.Fatal(err)
				}
				// Keep the retired directory outside enumeration, without releasing its inode.
				if err := os.Rename(packageRoot+"-retired", filepath.Join(t.TempDir(), "retired")); err != nil {
					t.Fatal(err)
				}
				writePackage(packageRoot, fixture.Manifest)
			case "workspace":
				ownerCheck = func() error { return configfile.ErrConflict }
			}
			result, err := service.SaveSettingsEditor(ctx, editor, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("false")}}, ownerCheck)
			if change != "save" {
				if !errors.Is(err, configfile.ErrConflict) || result.Committed {
					t.Fatalf("changed %s published: %+v %v", change, result, err)
				}
				if _, statErr := os.Stat(filepath.Join(preferences, "plugin-settings.json")); !errors.Is(statErr, os.ErrNotExist) {
					t.Fatalf("rejected save wrote source: %v", statErr)
				}
				return
			}
			if err != nil || !result.Committed || result.Readback == nil {
				t.Fatalf("save=%+v error=%v", result, err)
			}
			reopened, err := service.LoadSettingsEditor(ctx, "dev.example.settings", "")
			if err != nil {
				t.Fatal(err)
			}
			if string(reopened.Snapshot.State.Settings["flag"]) != "false" {
				t.Fatalf("reopen lost saved value: %+v", reopened.Snapshot.State.Settings)
			}
			// Installed resources remain exact inputs; the write belongs to preferences.
			actual, err := os.ReadFile(filepath.Join(packageRoot, pluginpkg.ManifestFile))
			if err != nil || string(actual) != string(fixture.Manifest) {
				t.Fatalf("installed manifest changed: %v", err)
			}
		})
	}
}

func TestInstalledSettingsRejectsManifestForAnotherRegistration(t *testing.T) {
	for _, field := range []string{"id", "version"} {
		t.Run(field, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
			if err != nil {
				t.Fatal(err)
			}
			var fixture struct {
				Manifest json.RawMessage `json:"manifest"`
			}
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatal(err)
			}
			var manifest map[string]any
			if err := json.Unmarshal(fixture.Manifest, &manifest); err != nil {
				t.Fatal(err)
			}
			if field == "id" {
				manifest["id"] = "dev.example.other"
			} else {
				manifest["version"] = "1.1.0"
			}
			malformed, err := json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			plugins, preferences := t.TempDir(), t.TempDir()
			directory := filepath.Join(plugins, "dev.example.settings", "1.0.0")
			if err := os.MkdirAll(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), malformed, 0o600); err != nil {
				t.Fatal(err)
			}
			kernel := &settingsPlanningKernel{fakeKernel: &fakeKernel{}, client: core.NewClient()}
			service, err := Open(kernel, store.At(preferences), plugins)
			if err != nil {
				t.Fatal(err)
			}
			catalog, err := service.SettingsCatalog(ctx)
			if err == nil || len(catalog) != 0 {
				t.Fatalf("mismatched package entered settings catalog: %+v %v", catalog, err)
			}
			if _, err := service.LoadSettingsEditor(ctx, "dev.example.settings", ""); err == nil {
				t.Fatal("mismatched package acquired an editable source")
			}
		})
	}
}
