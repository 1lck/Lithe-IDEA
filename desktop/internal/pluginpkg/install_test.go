package pluginpkg

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// newStaging creates a staging directory that looks like an extracted package,
// below the root's staging area so the install rename stays on one file system.
func newStaging(t *testing.T, root string) string {
	t.Helper()
	stagingRoot := filepath.Join(root, stagingDirectory)
	if err := os.MkdirAll(stagingRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	staging, err := os.MkdirTemp(stagingRoot, "package-")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, ManifestFile), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	return staging
}

func TestInstallMovesStagingIntoRoot(t *testing.T) {
	root := t.TempDir()
	staging := newStaging(t, root)
	installed, err := Install(root, "io.github.lithe-idea.java-support", "1.2.3", staging)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	want := filepath.Join(root, "io.github.lithe-idea.java-support", "1.2.3")
	if installed.Path != want || installed.ID != "io.github.lithe-idea.java-support" || installed.Version != "1.2.3" {
		t.Fatalf("installed = %+v", installed)
	}
	if _, err := os.Stat(filepath.Join(want, ManifestFile)); err != nil {
		t.Fatalf("manifest missing after install: %v", err)
	}
	if _, err := os.Stat(staging); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging survived the install: %v", err)
	}
}

func TestInstallRefusesExistingVersion(t *testing.T) {
	root := t.TempDir()
	if _, err := Install(root, "example", "1.0.0", newStaging(t, root)); err != nil {
		t.Fatalf("first install: %v", err)
	}
	marker := filepath.Join(root, "example", "1.0.0", "marker")
	if err := os.WriteFile(marker, []byte("kept"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(root, "example", "1.0.0", newStaging(t, root)); !errors.Is(err, ErrPackageExists) {
		t.Fatalf("err = %v", err)
	}
	if body, err := os.ReadFile(marker); err != nil || string(body) != "kept" {
		t.Fatalf("the existing version was disturbed: %q, %v", body, err)
	}
}

func TestInstallRefusesUnsafeIdentity(t *testing.T) {
	cases := map[string]struct{ id, version string }{
		"empty ID":            {"", "1.0.0"},
		"empty version":       {"example", ""},
		"ID with separator":   {"a/b", "1.0.0"},
		"ID with backslash":   {`a\b`, "1.0.0"},
		"ID is parent":        {"..", "1.0.0"},
		"ID is current":       {".", "1.0.0"},
		"ID starts with dot":  {".hidden", "1.0.0"},
		"version is parent":   {"example", ".."},
		"version has slash":   {"example", "1/2"},
		"version starts dot":  {"example", ".1"},
		"ID is a device name": {"CON", "1.0.0"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			if _, err := Install(root, tc.id, tc.version, newStaging(t, root)); !errors.Is(err, ErrInvalidIdentity) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestInstallRefusesRelativePaths(t *testing.T) {
	root := t.TempDir()
	if _, err := Install("relative/root", "example", "1.0.0", newStaging(t, root)); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("relative root: %v", err)
	}
	if _, err := Install(root, "example", "1.0.0", "relative/staging"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("relative staging: %v", err)
	}
}

func TestUninstallRemovesVersionAndEmptyID(t *testing.T) {
	root := t.TempDir()
	if _, err := Install(root, "example", "1.0.0", newStaging(t, root)); err != nil {
		t.Fatal(err)
	}
	if err := Uninstall(root, "example", "1.0.0"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "example")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the ID directory survived: %v", err)
	}
}

func TestUninstallKeepsOtherVersions(t *testing.T) {
	root := t.TempDir()
	for _, version := range []string{"1.0.0", "1.1.0"} {
		if _, err := Install(root, "example", version, newStaging(t, root)); err != nil {
			t.Fatal(err)
		}
	}
	if err := Uninstall(root, "example", "1.0.0"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "example", "1.1.0", ManifestFile)); err != nil {
		t.Fatalf("the remaining version was removed: %v", err)
	}
}

func TestUninstallRefusesMissingVersion(t *testing.T) {
	if err := Uninstall(t.TempDir(), "example", "1.0.0"); !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("err = %v", err)
	}
}

func TestUninstallRefusesUnsafeIdentity(t *testing.T) {
	if err := Uninstall(t.TempDir(), "..", "1.0.0"); !errors.Is(err, ErrInvalidIdentity) {
		t.Fatalf("err = %v", err)
	}
}

func TestListSkipsReservedDirectoriesAndSorts(t *testing.T) {
	root := t.TempDir()
	for _, item := range []struct{ id, version string }{
		{"zeta", "2.0.0"},
		{"alpha", "1.1.0"},
		{"alpha", "1.0.0"},
	} {
		if _, err := Install(root, item.id, item.version, newStaging(t, root)); err != nil {
			t.Fatal(err)
		}
	}
	// A leftover of an interrupted operation must never look installed.
	if err := os.MkdirAll(filepath.Join(root, trashDirectory, "uninstall-1"), 0o700); err != nil {
		t.Fatal(err)
	}
	installed, err := List(root)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	want := []string{"alpha 1.0.0", "alpha 1.1.0", "zeta 2.0.0"}
	if len(installed) != len(want) {
		t.Fatalf("installed = %+v", installed)
	}
	for i, entry := range installed {
		if entry.ID+" "+entry.Version != want[i] {
			t.Fatalf("entry %d = %q %q, want %q", i, entry.ID, entry.Version, want[i])
		}
	}
}

func TestListReturnsNothingForMissingRoot(t *testing.T) {
	installed, err := List(filepath.Join(t.TempDir(), "absent"))
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(installed) != 0 {
		t.Fatalf("installed = %+v", installed)
	}
}

func TestDefaultRootIsAbsolute(t *testing.T) {
	root, err := DefaultRoot()
	if err != nil {
		t.Skipf("this machine has no default plugin root: %v", err)
	}
	if !filepath.IsAbs(root) {
		t.Fatalf("root = %q", root)
	}
}
