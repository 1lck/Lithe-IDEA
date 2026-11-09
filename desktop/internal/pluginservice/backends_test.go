package pluginservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// serverPackage writes an installed package whose manifest declares language
// servers for the given languages.
func serverPackage(t *testing.T, version string, enabled bool, languages ...string) pluginmanager.Entry {
	t.Helper()
	declaration := `{"id":"example","version":"` + version + `","languageServers":[`
	for i, language := range languages {
		if i > 0 {
			declaration += ","
		}
		declaration += `{"languageID":"` + language + `"}`
	}
	declaration += `]}`
	directory := filepath.Join(t.TempDir(), "example", version)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, pluginpkg.ManifestFile), []byte(declaration), 0o600); err != nil {
		t.Fatal(err)
	}
	return pluginmanager.Entry{
		Installed: pluginpkg.Installed{ID: "example", Version: version, Path: directory},
		Enabled:   enabled,
	}
}

func TestLanguageServerProviderFindsAnEnabledPlugin(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := serverPackage(t, "1.0.0", true, "java")
	found, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{entry}, "java")
	if err != nil {
		t.Fatalf("provider: %v", err)
	}
	if !ok || found.Installed.Version != "1.0.0" {
		t.Fatalf("found = %+v, ok = %v", found, ok)
	}
}

func TestLanguageServerProviderSkipsDisabledPlugins(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := serverPackage(t, "1.0.0", false, "java")
	if _, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{entry}, "java"); ok || err != nil {
		t.Fatalf("ok = %v, err = %v", ok, err)
	}
}

func TestLanguageServerProviderIgnoresUndeclaredLanguages(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	entry := serverPackage(t, "1.0.0", true, "java")
	if _, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{entry}, "kotlin"); ok || err != nil {
		t.Fatalf("ok = %v, err = %v", ok, err)
	}
	if _, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{entry}, ""); ok || err != nil {
		t.Fatalf("ok = %v, err = %v", ok, err)
	}
}

func TestLanguageServerProviderUsesTheNewestVersion(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// Both versions are installed and enabled; the newer one must answer.
	older := serverPackage(t, "1.0.0", true, "java")
	newer := serverPackage(t, "1.1.0", true, "java")
	found, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{older, newer}, "java")
	if err != nil {
		t.Fatalf("provider: %v", err)
	}
	if !ok || found.Installed.Version != "1.1.0" {
		t.Fatalf("found = %+v, ok = %v", found, ok)
	}
}

func TestLanguageServerProviderReportsABrokenPackage(t *testing.T) {
	service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	broken := pluginmanager.Entry{
		Installed: pluginpkg.Installed{ID: "broken", Version: "1.0.0", Path: filepath.Join(t.TempDir(), "absent")},
		Enabled:   true,
	}
	healthy := serverPackage(t, "1.0.0", true, "java")
	found, ok, err := service.LanguageServerProvider(context.Background(), []pluginmanager.Entry{broken, healthy}, "java")
	if !errors.Is(err, ErrPackageRead) {
		t.Fatalf("err = %v", err)
	}
	// A broken package does not hide the working provider.
	if !ok || found.Installed.Version != "1.0.0" {
		t.Fatalf("found = %+v, ok = %v", found, ok)
	}
}

func TestLanguageServerProviderSelectsNumericNewestVersionIndependentlyOfDirectoryOrder(t *testing.T) {
	for _, reverse := range []bool{false, true} {
		t.Run(map[bool]string{false: "numeric-order", true: "lexical-directory-order"}[reverse], func(t *testing.T) {
			service, err := Open(&fakeKernel{}, store.At(t.TempDir()), t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			older := serverPackage(t, "0.9.0", true, "fixture")
			newer := serverPackage(t, "0.10.0", true, "fixture")
			entries := []pluginmanager.Entry{older, newer}
			if reverse {
				entries = []pluginmanager.Entry{newer, older}
			}
			selected, ok, err := service.LanguageServerProvider(context.Background(), entries, "fixture")
			if err != nil || !ok || selected.Installed.Version != "0.10.0" {
				t.Fatalf("numeric newest version not selected: version=%q, found=%v, error=%v", selected.Installed.Version, ok, err)
			}
		})
	}
}
