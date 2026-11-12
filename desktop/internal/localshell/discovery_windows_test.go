//go:build windows

package localshell

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows/registry"
)

func TestWindowsShellDiscoveryFindsInstallationsOutsidePATH(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "PowerShell", "7", "pwsh.exe")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("test executable location"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	t.Setenv("ProgramW6432", root)
	t.Setenv("ProgramFiles", root)
	t.Setenv("ProgramFiles(x86)", "")
	choices := InstalledWindowsShells()
	for _, choice := range choices {
		if choice.Name == "PowerShell 7" {
			if choice.Path != path {
				t.Fatalf("PowerShell path=%q, want %q", choice.Path, path)
			}
			return
		}
	}
	t.Fatalf("installed PowerShell was not detected: %+v", choices)
}

// TestWindowsShellDiscoveryFindsCygwin covers the setup program's default
// roots beside the system drive, which PATH does not carry (issue #435).
func TestWindowsShellDiscoveryFindsCygwin(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "cygwin64", "bin", "bash.exe")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("test executable location"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	t.Setenv("SystemDrive", root)
	choices := InstalledWindowsShells()
	for _, choice := range choices {
		if choice.Name == "Cygwin" {
			if choice.Path != path {
				t.Fatalf("Cygwin path=%q, want %q", choice.Path, path)
			}
			return
		}
	}
	t.Fatalf("installed Cygwin was not detected: %+v", choices)
}

// stubCygwinRegistry replaces the registry reader for one test. roots maps a
// probe to what that key records; a probe the map omits records nothing.
func stubCygwinRegistry(t *testing.T, roots map[cygwinSetupProbe]string) {
	t.Helper()
	previous := cygwinRootFromRegistry
	cygwinRootFromRegistry = func(probe cygwinSetupProbe) string { return roots[probe] }
	t.Cleanup(func() { cygwinRootFromRegistry = previous })
}

// writeShell creates a stand-in bash.exe at root\bin and returns its path.
func writeShell(t *testing.T, root string) string {
	t.Helper()
	path := filepath.Join(root, "bin", "bash.exe")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("test executable location"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

// cygwinChoice returns the root Cygwin resolved to, and whether it was offered.
func cygwinChoice(choices []Choice) (string, bool) {
	for _, choice := range choices {
		if choice.Name == "Cygwin" {
			return choice.Path, true
		}
	}
	return "", false
}

// The root the setup program recorded wins over the defaults beside the system
// drive: a Cygwin installed to a directory of the user's choosing is only
// named there (issue #435).
func TestWindowsShellDiscoveryPrefersTheRecordedCygwinRoot(t *testing.T) {
	customRoot := t.TempDir()
	custom := writeShell(t, customRoot)
	defaultRoot := t.TempDir()
	writeShell(t, filepath.Join(defaultRoot, "cygwin64"))
	t.Setenv("PATH", t.TempDir())
	t.Setenv("SystemDrive", defaultRoot)
	stubCygwinRegistry(t, map[cygwinSetupProbe]string{
		{registry.CURRENT_USER, registry.WOW64_64KEY}: customRoot,
	})
	if roots := cygwinRecordedRoots(); len(roots) != 1 || roots[0] != customRoot {
		t.Fatalf("recorded roots = %q, want just %q", roots, customRoot)
	}

	got, ok := cygwinChoice(InstalledWindowsShells())
	if !ok {
		t.Fatal("the recorded root was not offered")
	}
	if got != custom {
		t.Fatalf("Cygwin path=%q, want the shell under the recorded root %q", got, custom)
	}
}

// A 32-bit setup on a 64-bit Windows writes under its own view of the key, and
// a per-user install writes under the user's hive; both are read.
func TestWindowsShellDiscoveryReadsEveryCygwinSetupKey(t *testing.T) {
	for _, probe := range []cygwinSetupProbe{
		{registry.CURRENT_USER, registry.WOW64_64KEY},
		{registry.CURRENT_USER, registry.WOW64_32KEY},
		{registry.LOCAL_MACHINE, registry.WOW64_64KEY},
		{registry.LOCAL_MACHINE, registry.WOW64_32KEY},
	} {
		root := t.TempDir()
		shell := writeShell(t, root)
		t.Setenv("PATH", t.TempDir())
		t.Setenv("SystemDrive", t.TempDir())
		stubCygwinRegistry(t, map[cygwinSetupProbe]string{probe: root})
		got, ok := cygwinChoice(InstalledWindowsShells())
		if !ok || got != shell {
			t.Fatalf("probe %v: Cygwin=%q found=%v, want %q", probe, got, ok, shell)
		}
	}
}

// The same root recorded in several keys is offered once, and a record whose
// bash.exe is missing falls back to the default roots rather than hiding Cygwin.
func TestWindowsShellDiscoveryDeduplicatesAndFallsBack(t *testing.T) {
	sharedRoot := t.TempDir()
	sharedShell := writeShell(t, sharedRoot)
	t.Setenv("PATH", t.TempDir())
	defaultRoot := t.TempDir()
	defaultShell := writeShell(t, filepath.Join(defaultRoot, "cygwin64"))
	t.Setenv("SystemDrive", defaultRoot)
	stubCygwinRegistry(t, map[cygwinSetupProbe]string{
		{registry.CURRENT_USER, registry.WOW64_64KEY}:  sharedRoot,
		{registry.LOCAL_MACHINE, registry.WOW64_64KEY}: sharedRoot,
	})
	choices := InstalledWindowsShells()
	got, ok := cygwinChoice(choices)
	if !ok || got != sharedShell {
		t.Fatalf("Cygwin=%q found=%v, want %q", got, ok, sharedShell)
	}
	count := 0
	for _, choice := range choices {
		if choice.Name == "Cygwin" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("Cygwin was offered %d times", count)
	}

	// A record naming a root with no bash.exe must not stop discovery.
	emptyRoot := t.TempDir()
	stubCygwinRegistry(t, map[cygwinSetupProbe]string{
		{registry.CURRENT_USER, registry.WOW64_64KEY}: emptyRoot,
	})
	if got, ok := cygwinChoice(InstalledWindowsShells()); !ok || got != defaultShell {
		t.Fatalf("a stale record hid the default Cygwin: %q %v", got, ok)
	}
}
