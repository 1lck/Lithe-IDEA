package toolchain

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// sameFolder compares a folder Core lists with a native path, in the platform's path identity.
func sameFolder(listed, native string) bool {
	a, b := filepath.Clean(filepath.FromSlash(listed)), filepath.Clean(native)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

func readCatalogBytes(t *testing.T, settings string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(settings, "toolchains", "global.json"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestTrustedLocationsPreviewWritesNothingAndSaveTrustsNestedWorkspaces(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settings := filepath.Join(t.TempDir(), "user-settings")
	first, second := canonical(t, t.TempDir()), canonical(t, t.TempDir())

	locations, err := ReadTrustedLocations(ctx, kernel, settings)
	if err != nil {
		t.Fatal(err)
	}
	if len(locations.Locations) != 0 {
		t.Fatalf("a missing catalog listed locations: %v", locations.Locations)
	}
	// The user adds both folders, then changes their mind about the first.
	changes := []LocationChange{{Folder: first, Add: true}, {Folder: second, Add: true}, {Folder: first}}
	preview, err := locations.Preview(ctx, kernel, changes)
	if err != nil {
		t.Fatal(err)
	}
	if len(preview) != 1 || !sameFolder(preview[0], second) {
		t.Fatalf("preview = %v, want only %s", preview, second)
	}
	if _, err := os.Stat(settings); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reading and previewing created the preference directory: %v", err)
	}

	if changed, err := locations.Save(ctx, kernel, changes); err != nil || !changed {
		t.Fatalf("save = %v, %v", changed, err)
	}
	saved, err := ReadTrustedLocations(ctx, kernel, settings)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved.Locations) != 1 || !sameFolder(saved.Locations[0], second) {
		t.Fatalf("saved locations = %v, want only %s", saved.Locations, second)
	}
	nested := filepath.Join(second, "group", "project")
	document, err := saved.catalog.file.Text()
	if err != nil {
		t.Fatal(err)
	}
	state, err := kernel.ReadToolchainCatalogForWorkspace(ctx, document, saved.catalog.platform, nested)
	if err != nil {
		t.Fatal(err)
	}
	if state.WorkspaceTrust == nil || state.WorkspaceTrust.State != core.WorkspaceTrusted ||
		state.WorkspaceTrust.Location == nil || !sameFolder(*state.WorkspaceTrust.Location, second) {
		t.Fatalf("a project inside the trusted folder = %+v", state.WorkspaceTrust)
	}

	// The list read before the write is stale now.
	if _, err := locations.Save(ctx, kernel, []LocationChange{{Folder: first, Add: true}}); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("a stale list was written over: %v", err)
	}
}

func TestTrustedLocationsChangesThatCancelOutWriteNothing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settings := filepath.Join(t.TempDir(), "user-settings")
	first, second := canonical(t, t.TempDir()), canonical(t, t.TempDir())
	initial, err := ReadTrustedLocations(ctx, kernel, settings)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := initial.Save(ctx, kernel, []LocationChange{{Folder: first, Add: true}, {Folder: second, Add: true}}); err != nil {
		t.Fatal(err)
	}
	before := readCatalogBytes(t, settings)
	locations, err := ReadTrustedLocations(ctx, kernel, settings)
	if err != nil {
		t.Fatal(err)
	}
	// Removing the first folder and adding it again only moves it to the end of the list.
	changed, err := locations.Save(ctx, kernel, []LocationChange{{Folder: first}, {Folder: first, Add: true}})
	if err != nil || changed {
		t.Fatalf("save = %v, %v; want nothing written", changed, err)
	}
	if after := readCatalogBytes(t, settings); !bytes.Equal(before, after) {
		t.Fatalf("a save that changes nothing rewrote the catalog:\n%s\n%s", before, after)
	}
}

func TestTrustedLocationsRefuseAFilesystemRootAndNameTheChange(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settings := filepath.Join(t.TempDir(), "user-settings")
	folder := canonical(t, t.TempDir())
	root := filepath.VolumeName(folder) + string(filepath.Separator)
	locations, err := ReadTrustedLocations(ctx, kernel, settings)
	if err != nil {
		t.Fatal(err)
	}
	_, err = locations.Preview(ctx, kernel, []LocationChange{{Folder: folder, Add: true}, {Folder: root, Add: true}})
	var change *LocationChangeError
	if !errors.As(err, &change) || change.Index != 1 {
		t.Fatalf("preview error = %v, want the second change refused", err)
	}
	var rejection *core.MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.toolchain.rootLocation" {
		t.Fatalf("preview error = %v, want plugin.toolchain.rootLocation", err)
	}
	if changed, err := locations.Save(ctx, kernel, []LocationChange{{Folder: root, Add: true}}); changed || !errors.As(err, &rejection) {
		t.Fatalf("save of a root = %v, %v", changed, err)
	}
	if _, err := os.Stat(settings); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused save created the preference directory: %v", err)
	}
}

func TestReadTrustedLocationsNeedsThePreferenceDirectory(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := ReadTrustedLocations(ctx, core.NewClient(), ""); err == nil {
		t.Fatal("read without a preference directory succeeded")
	}
	var empty TrustedLocations
	if _, err := empty.Save(ctx, core.NewClient(), []LocationChange{{Folder: "/tmp", Add: true}}); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("save of a list never read = %v", err)
	}
}
