//go:build !windows

package localshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestUnixShellDiscoveryFindsTheStandardShells checks the non-Windows list the
// settings offer: at least the platform's /bin/sh, by an absolute path.
func TestUnixShellDiscoveryFindsTheStandardShells(t *testing.T) {
	choices := InstalledShells()
	if len(choices) == 0 {
		t.Fatal("no local shells were discovered")
	}
	found := false
	for _, choice := range choices {
		if !filepath.IsAbs(choice.Path) {
			t.Fatalf("shell %q is not an absolute path", choice.Path)
		}
		if choice.Path == "/bin/sh" {
			found = true
		}
	}
	if !found {
		t.Fatalf("shells %+v do not include /bin/sh", choices)
	}
}

// TestUnixShellDiscoveryReadsTheSystemShellFile checks that a shell the system
// accapts for login appears even when this file has never heard of it: the
// shell file is the authority on what the machine offers, and a shell installed
// later lands there rather than in a table in this repository.
func TestUnixShellDiscoveryReadsTheSystemShellFile(t *testing.T) {
	root := t.TempDir()
	installed := writeExecutable(t, root, "myshell")

	shellFile := filepath.Join(root, "shells")
	contents := "# a comment\n\n" + installed + "\n" + filepath.Join(root, "does-not-exist") + "\n"
	if err := os.WriteFile(shellFile, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	restoreShellFile := pointShellFileAt(t, shellFile)
	defer restoreShellFile()

	choices := InstalledShells()
	if !hasShell(choices, installed) {
		t.Fatalf("shells %+v do not include %q from the system shell file", choices, installed)
	}
	for _, choice := range choices {
		if choice.Path == filepath.Join(root, "does-not-exist") {
			t.Fatalf("shells %+v include an entry that is not installed", choices)
		}
	}
}

// TestUnixShellDiscoveryFindsShellsOutsidePATH is the case an application
// started from the Finder meets: launchd hands it /usr/bin:/bin:/usr/sbin:/sbin,
// which holds no Homebrew prefix, so a shell installed with brew is not on PATH
// at all. The standard prefixes are searched directly, so it still appears.
func TestUnixShellDiscoveryFindsShellsOutsidePATH(t *testing.T) {
	homebrew := t.TempDir()
	fish := writeExecutable(t, homebrew, "fish")
	elvish := writeExecutable(t, homebrew, "elvish")

	restorePrefixes := pointShellPrefixesAt(t, homebrew)
	defer restorePrefixes()

	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	for _, name := range []string{"fish", "elvish"} {
		if path, err := exec.LookPath(name); err == nil && filepath.Dir(path) == homebrew {
			t.Fatalf("%s is on PATH (%s); the test does not reproduce a Finder launch", name, path)
		}
	}

	choices := InstalledShells()
	if !hasShell(choices, fish) {
		t.Fatalf("shells %+v do not include %q found by searching %q", choices, fish, homebrew)
	}
	if !hasShell(choices, elvish) {
		t.Fatalf("shells %+v do not include %q found by searching %q", choices, elvish, homebrew)
	}
}

// TestUnixShellDiscoveryListsEachInstallation checks the list's shape: the
// system's bash and Homebrew's are separate programs, often of different
// versions, so the new-terminal menu offers both, in the order the places are
// searched.
func TestUnixShellDiscoveryListsEachInstallation(t *testing.T) {
	first := t.TempDir()
	second := t.TempDir()
	older := writeExecutable(t, first, "fish")
	newer := writeExecutable(t, second, "fish")

	restorePrefixes := pointShellPrefixesAt(t, first, second)
	defer restorePrefixes()
	restoreShellFile := pointShellFileAt(t, filepath.Join(first, "no-shells"))
	defer restoreShellFile()
	t.Setenv("PATH", t.TempDir())

	var fish []string
	for _, choice := range InstalledShells() {
		if choice.Name == "fish" {
			fish = append(fish, choice.Path)
		}
	}
	if len(fish) != 2 || fish[0] != older || fish[1] != newer {
		t.Fatalf("fish entries = %q, want %q then %q", fish, older, newer)
	}
}

// TestUnixShellDiscoveryMergesPlacesOfOneFile checks the other half of that
// shape: a shell reached by a symbolic link from another prefix, and again by
// its bare name on PATH, is one installation and keeps the first place found.
func TestUnixShellDiscoveryMergesPlacesOfOneFile(t *testing.T) {
	cellar := t.TempDir()
	linked := t.TempDir()
	fish := writeExecutable(t, cellar, "fish")
	if err := os.Symlink(fish, filepath.Join(linked, "fish")); err != nil {
		t.Skipf("symbolic links are not available: %v", err)
	}

	restorePrefixes := pointShellPrefixesAt(t, cellar, linked)
	defer restorePrefixes()
	restoreShellFile := pointShellFileAt(t, filepath.Join(cellar, "no-shells"))
	defer restoreShellFile()
	t.Setenv("PATH", linked)

	var entries []string
	for _, choice := range InstalledShells() {
		if choice.Name == "fish" {
			entries = append(entries, choice.Path)
		}
	}
	if len(entries) != 1 || entries[0] != fish {
		t.Fatalf("fish entries = %q, want only %q", entries, fish)
	}
}

// TestUnixShellDiscoveryCollapsesCShellHardLinks checks the macOS layout:
// /bin/csh and /bin/tcsh are two names for one executable, so the picker
// offers the C shell once instead of repeating the same program.
func TestUnixShellDiscoveryCollapsesCShellHardLinks(t *testing.T) {
	root := t.TempDir()
	tcsh := writeExecutable(t, root, "tcsh")
	csh := filepath.Join(root, "csh")
	if err := os.Link(tcsh, csh); err != nil {
		t.Skipf("hard links are not available: %v", err)
	}

	restorePrefixes := pointShellPrefixesAt(t, root)
	defer restorePrefixes()
	restoreShellFile := pointShellFileAt(t, filepath.Join(root, "no-shells"))
	defer restoreShellFile()
	t.Setenv("PATH", t.TempDir())

	choices := InstalledShells()
	count := 0
	for _, choice := range choices {
		if choice.Name == "csh" || choice.Name == "tcsh" {
			count++
		}
	}
	if count != 1 || !hasShell(choices, tcsh) || hasShell(choices, csh) {
		t.Fatalf("C shell entries = %+v, want only %q", choices, tcsh)
	}
}

// TestUnixShellDiscoveryKeepsShWithItsTarget checks that collapsing one file
// reached by two names does not remove sh: on many systems /bin/sh links to
// dash or bash, but argv[0] selects POSIX mode, a distinct interactive shell.
func TestUnixShellDiscoveryKeepsShWithItsTarget(t *testing.T) {
	root := t.TempDir()
	dash := writeExecutable(t, root, "dash")
	sh := filepath.Join(root, "sh")
	if err := os.Symlink("dash", sh); err != nil {
		t.Skipf("symbolic links are not available: %v", err)
	}

	restorePrefixes := pointShellPrefixesAt(t, root)
	defer restorePrefixes()
	restoreShellFile := pointShellFileAt(t, filepath.Join(root, "no-shells"))
	defer restoreShellFile()
	t.Setenv("PATH", t.TempDir())

	choices := InstalledShells()
	if !hasShell(choices, dash) || !hasShell(choices, sh) {
		t.Fatalf("shells = %+v, want both %q and %q", choices, dash, sh)
	}
}

// writeExecutable creates an empty executable file and returns its path.
func writeExecutable(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func hasShell(choices []Choice, path string) bool {
	for _, choice := range choices {
		if choice.Path == path {
			return true
		}
	}
	return false
}

// pointShellFileAt makes the package read another shell file, returning the
// function that puts the original back.
func pointShellFileAt(t *testing.T, path string) func() {
	t.Helper()
	original := systemShellFile
	systemShellFile = path
	return func() { systemShellFile = original }
}

// pointShellPrefixesAt makes the package search other prefixes, returning the
// function that puts the original list back.
func pointShellPrefixesAt(t *testing.T, prefixes ...string) func() {
	t.Helper()
	original := shellPrefixes
	shellPrefixes = prefixes
	return func() { shellPrefixes = original }
}
