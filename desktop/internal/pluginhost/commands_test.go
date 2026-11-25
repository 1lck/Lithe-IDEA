package pluginhost

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const commandTestPlugin = "dev.lithe.test.commands"

// writeCommand puts an executable command named name in directory.
func writeCommand(t *testing.T, directory, name string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func notFound(string) (string, error) { return "", errors.New("not found") }

func TestCommandStoreInstallDirectoryStaysBelowThePluginState(t *testing.T) {
	state := t.TempDir()
	store := &CommandStore{State: state}
	directory, err := store.InstallDirectory(commandTestPlugin, "sample-ls")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(state, commandTestPlugin, "commands", "sample-ls"); directory != want {
		t.Fatalf("directory = %q, want %q", directory, want)
	}
	// Both IDs are joined into the path, so neither may leave the plugin's state.
	for _, ids := range [][2]string{{"../escape", "sample-ls"}, {".hidden", "sample-ls"}, {commandTestPlugin, "../x"}, {commandTestPlugin, "Upper"}, {commandTestPlugin, ""}} {
		if _, err := store.InstallDirectory(ids[0], ids[1]); err == nil {
			t.Fatalf("InstallDirectory(%q, %q) was accepted", ids[0], ids[1])
		}
	}
	if _, err := (&CommandStore{State: "relative"}).InstallDirectory(commandTestPlugin, "sample-ls"); err == nil {
		t.Fatal("a relative state directory was accepted")
	}
}

func TestCommandStoreRecordsAndReplacesInstallations(t *testing.T) {
	state := t.TempDir()
	store := &CommandStore{State: state}
	managed := filepath.Join(state, commandTestPlugin, "commands", "sample-ls", "bin")
	defaults := filepath.Join(t.TempDir(), "go", "bin")
	if err := store.Record(commandTestPlugin, CommandInstallation{Installer: "sample-dap", Target: core.CommandInstallToolDefault, Directory: defaults}); err != nil {
		t.Fatal(err)
	}
	if err := store.Record(commandTestPlugin, CommandInstallation{Installer: "sample-ls", Target: core.CommandInstallManaged, Directory: defaults}); err != nil {
		t.Fatal(err)
	}
	// Installing the same installer again replaces its entry.
	if err := store.Record(commandTestPlugin, CommandInstallation{Installer: "sample-ls", Target: core.CommandInstallManaged, Directory: managed}); err != nil {
		t.Fatal(err)
	}
	if got := store.Installations(commandTestPlugin); len(got) != 2 {
		t.Fatalf("installations = %+v", got)
	}
	// Managed directories come first.
	if got := strings.Join(store.Directories(commandTestPlugin), "|"); got != managed+"|"+defaults {
		t.Fatalf("directories = %q", got)
	}
	// A record of one plugin is not read for another.
	if got := store.Directories("dev.lithe.test.other"); len(got) != 0 {
		t.Fatalf("other plugin's directories = %v", got)
	}
	for _, bad := range []CommandInstallation{
		{Installer: "sample-ls", Target: "elsewhere", Directory: managed},
		{Installer: "sample-ls", Target: core.CommandInstallManaged, Directory: "relative/bin"},
		{Installer: "../x", Target: core.CommandInstallManaged, Directory: managed},
	} {
		if err := store.Record(commandTestPlugin, bad); !errors.Is(err, ErrCommandRecord) {
			t.Fatalf("Record(%+v) = %v", bad, err)
		}
	}
	entries, err := os.ReadDir(filepath.Join(state, commandTestPlugin))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".") || strings.HasSuffix(entry.Name(), ".tmp") {
			t.Fatalf("temporary file %s was left behind", entry.Name())
		}
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Join(state, commandTestPlugin, commandRecordName))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("record permissions = %v, %v", info, err)
		}
	}
}

func TestCommandStoreReadsAnUnusableRecordAsEmpty(t *testing.T) {
	state := t.TempDir()
	store := &CommandStore{State: state}
	directory := filepath.Join(state, commandTestPlugin)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	record := filepath.Join(directory, "commands.json")
	for _, data := range []string{
		"{not json",
		`{"installations":[{"installer":"sample-ls","target":"managed","directory":"relative"}]}`,
		`{"installations":[{"installer":"sample-ls","target":"managed","directory":"` + strings.Repeat("a", maxCommandRecordBytes) + `"}]}`,
	} {
		if err := os.WriteFile(record, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := store.Directories(commandTestPlugin); len(got) != 0 {
			t.Fatalf("directories = %v for record %.40q", got, data)
		}
	}
	// A corrupt record does not stop a new installation from being recorded.
	bin := filepath.Join(t.TempDir(), "bin")
	if err := store.Record(commandTestPlugin, CommandInstallation{Installer: "sample-ls", Target: core.CommandInstallToolDefault, Directory: bin}); err != nil {
		t.Fatal(err)
	}
	if got := store.Directories(commandTestPlugin); len(got) != 1 || got[0] != bin {
		t.Fatalf("directories = %v", got)
	}
}

func TestCommandStoreLookupTriesPathThenInstalledDirectories(t *testing.T) {
	state := t.TempDir()
	store := &CommandStore{State: state}
	managed := filepath.Join(state, commandTestPlugin, "commands", "sample-ls")
	installed := writeCommand(t, managed, "sample-ls")
	if err := store.Record(commandTestPlugin, CommandInstallation{Installer: "sample-ls", Target: core.CommandInstallManaged, Directory: managed}); err != nil {
		t.Fatal(err)
	}
	// PATH wins when it has the command.
	onPath := func(name string) (string, error) {
		if name == "sample-ls" {
			return "/usr/bin/sample-ls", nil
		}
		return "", errors.New("not found")
	}
	if path, err := ResolveCommand([]string{"sample-ls"}, store.Lookup(commandTestPlugin, onPath)); err != nil || path != "/usr/bin/sample-ls" {
		t.Fatalf("path = %q, err = %v", path, err)
	}
	// Otherwise the installed command is found, and only for its own plugin.
	if path, err := ResolveCommand([]string{"sample-ls"}, store.Lookup(commandTestPlugin, notFound)); err != nil || path != installed {
		t.Fatalf("path = %q, err = %v", path, err)
	}
	var missing *CommandMissingError
	if _, err := ResolveCommand([]string{"sample-ls"}, store.Lookup("dev.lithe.test.other", notFound)); !errors.As(err, &missing) {
		t.Fatalf("err = %v", err)
	}
	if _, err := ResolveCommand([]string{"sample-dap"}, store.Lookup(commandTestPlugin, notFound)); !errors.As(err, &missing) {
		t.Fatalf("err = %v", err)
	}
	// A nil store looks up PATH only.
	var none *CommandStore
	if _, err := ResolveCommand([]string{"sample-ls"}, none.Lookup(commandTestPlugin, onPath)); err != nil {
		t.Fatal(err)
	}
}

func TestCommandInDirectoryRefusesPaths(t *testing.T) {
	directory := t.TempDir()
	writeCommand(t, directory, "tool")
	if _, err := CommandInDirectory(directory, "tool"); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"", ".", "..", "../tool", `sub\tool`} {
		if _, err := CommandInDirectory(directory, name); err == nil {
			t.Fatalf("CommandInDirectory(%q) was accepted", name)
		}
	}
	if runtime.GOOS != "windows" {
		// A file without the executable bit is not a command.
		plain := filepath.Join(directory, "plain")
		if err := os.WriteFile(plain, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := CommandInDirectory(directory, "plain"); err == nil {
			t.Fatal("a non-executable file was accepted")
		}
	}
}
