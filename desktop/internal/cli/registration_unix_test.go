//go:build !windows

package cli

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestCLIRegistrationReadsWithoutWritingAndPublishesGuardedEdits(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	source := filepath.Join(root, ".zshrc")
	original := "# keep personal settings\nexport EDITOR=vi\n"
	if err := os.WriteFile(source, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	m := &Manager{Kernel: core.NewClient(), Directory: filepath.Join(root, "user bin"), Executable: "/Applications/Lithe's.app/Contents/MacOS/lithe", source: func(ctx context.Context) (nativeSource, error) { return captureSource(ctx, "zsh", source) }}
	state, err := m.Read(ctx)
	if err != nil || state.Installed {
		t.Fatalf("read: %+v %v", state, err)
	}
	if _, err := os.Stat(m.Directory); !os.IsNotExist(err) {
		t.Fatalf("read created launcher directory: %v", err)
	}
	state, err = m.Apply(ctx, state, true)
	if err != nil || !state.Installed {
		t.Fatalf("install/readback: %+v %v", state, err)
	}
	registered, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(registered), original) {
		t.Fatal("changed personal configuration")
	}
	state, err = m.Apply(ctx, state, true)
	if err != nil || !state.Installed {
		t.Fatalf("idempotent install: %v", err)
	}
	m.Executable = "/Applications/Updated Lithe.app/Contents/MacOS/lithe"
	state, err = m.Read(ctx)
	if err != nil || state.Installed || !state.Registered {
		t.Fatalf("moved installation status: %+v %v", state, err)
	}
	state, err = m.Apply(ctx, state, true)
	if err != nil || !state.Installed {
		t.Fatalf("repair moved installation: %v", err)
	}
	if err := os.WriteFile(source, append(registered, []byte("# external edit\n")...), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Apply(ctx, state, false); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("external edit overwritten: %v", err)
	}
	state, err = m.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	state, err = m.Apply(ctx, state, false)
	if err != nil || state.Installed {
		t.Fatalf("remove/readback: %v", err)
	}
	actual, err := os.ReadFile(source)
	if err != nil || string(actual) != original+"# external edit\n" {
		t.Fatalf("remove changed personal content: %q %v", actual, err)
	}
	if _, err := os.Stat(state.Launcher); !os.IsNotExist(err) {
		t.Fatalf("launcher left after removal: %v", err)
	}
}

func TestCLIRegistrationRejectsUnrelatedLauncherAndRetargetedSymlink(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	target := filepath.Join(root, "profile")
	link := filepath.Join(root, ".zshrc")
	if err := os.WriteFile(target, []byte("# dotfiles\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	m := &Manager{Kernel: core.NewClient(), Directory: filepath.Join(root, "bin"), Executable: "/app/lithe", source: func(ctx context.Context) (nativeSource, error) { return captureSource(ctx, "zsh", link) }}
	state, err := m.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(m.Directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(state.Launcher, []byte("#!/bin/sh\necho someone else\n"), 0700); err != nil {
		t.Fatal(err)
	}
	state, err = m.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Apply(ctx, state, true); !errors.Is(err, ErrLauncherConflict) {
		t.Fatalf("unrelated launcher overwritten: %v", err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(root, "other")
	if err := os.WriteFile(other, []byte("# other\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, link); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Apply(ctx, state, true); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("retargeted symlink not rejected: %v", err)
	}
}

func TestCLILauncherPreservesNativeArguments(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	executable := filepath.Join(root, "Lithe's app")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	edit, err := core.NewClient().EditCLIRegistration(ctx, "zsh", "", filepath.Join(root, "bin"), executable, "install", "")
	if err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(root, "lithe")
	if err := os.WriteFile(launcher, []byte(edit.Launcher), 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, launcher, "--", "-中文 file.txt")
	cmd.WaitDelay = time.Second
	output, err := cmd.CombinedOutput()
	if err != nil || string(output) != "--cli\n--\n-中文 file.txt\n" {
		t.Fatalf("launcher arguments: %q %v", output, err)
	}
}
