package remoteconn

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func seconds(value uint32) core.RemotePreferenceEdit {
	return core.RemotePreferenceEdit{ReconnectLimit: &core.RemoteReconnectLimitEdit{Seconds: &value}}
}

// Reading absent preferences creates nothing and reports the automatic values; a change writes
// only the preference document, and restoring the automatic value keeps the file without it.
func TestPreferencesWriteOnlyTheirDocument(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := filepath.Join(t.TempDir(), "preferences")
	home := t.TempDir()
	read, err := ReadPreferences(ctx, kernel, root, home)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reading created the preference root: %v", err)
	}
	state := read.State
	if state.Reconnect.Source != core.RemotePreferenceAutomatic || state.Reconnect.LimitSeconds != 60 || len(state.Reconnect.DelaysMilliseconds) != 6 {
		t.Fatalf("reconnect = %+v", state.Reconnect)
	}
	if state.Preferences.SSHProgram != nil || state.Preferences.ReconnectLimitSeconds != nil || state.SSH.Source != core.RemotePreferenceAutomatic {
		t.Fatalf("preferences = %+v, ssh source = %q", state.Preferences, state.SSH.Source)
	}
	if state.SSHConfig == nil || state.SSHConfig.Path != filepath.Join(home, ".ssh", "config") || state.SSHConfig.Exists {
		t.Fatalf("ssh config = %+v", state.SSHConfig)
	}
	changed, committed, err := read.Edit(ctx, kernel, seconds(3))
	if err != nil || !committed {
		t.Fatalf("edit: committed = %v, err = %v", committed, err)
	}
	if want := filepath.Join(root, "remote", "preferences.json"); changed.Path() != want {
		t.Fatalf("path = %q, want %q", changed.Path(), want)
	}
	reconnect := changed.State.Reconnect
	if reconnect.Source != core.RemotePreferenceFromSetting || reconnect.LimitSeconds != 3 || len(reconnect.DelaysMilliseconds) != 2 {
		t.Fatalf("after edit reconnect = %+v", reconnect)
	}
	if changed.State.SSHConfig == nil {
		t.Fatal("the edit dropped the home directory")
	}
	document, err := PreferencesDocument(ctx, kernel, root)
	if err != nil || document == nil {
		t.Fatalf("document = %v, err = %v", document != nil, err)
	}
	restored, committed, err := changed.Edit(ctx, kernel, core.RemotePreferenceEdit{ReconnectLimit: &core.RemoteReconnectLimitEdit{}})
	if err != nil || !committed || restored.State.Reconnect.Source != core.RemotePreferenceAutomatic {
		t.Fatalf("restore: committed = %v, source = %q, err = %v", committed, restored.State.Reconnect.Source, err)
	}
	same, committed, err := restored.Edit(ctx, kernel, core.RemotePreferenceEdit{ReconnectLimit: &core.RemoteReconnectLimitEdit{}})
	if err != nil || committed || same.State.Reconnect.LimitSeconds != 60 {
		t.Fatalf("unchanged edit: committed = %v, err = %v", committed, err)
	}
}

// A refused value names its field and writes nothing.
func TestRefusedPreferenceNamesTheField(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := t.TempDir()
	read, err := ReadPreferences(ctx, kernel, root, "")
	if err != nil {
		t.Fatal(err)
	}
	relative := "bin/ssh"
	_, committed, err := read.Edit(ctx, kernel, core.RemotePreferenceEdit{SSHProgram: &core.RemoteSSHProgramEdit{Path: &relative}})
	field, reason, ok := core.RemoteConnectionFieldError(err)
	if committed || !ok || field != "sshProgram" || reason != "relative" {
		t.Fatalf("relative program: committed = %v, field = %q, reason = %q", committed, field, reason)
	}
	_, committed, err = read.Edit(ctx, kernel, seconds(3601))
	field, reason, ok = core.RemoteConnectionFieldError(err)
	if committed || !ok || field != "reconnectLimitSeconds" || reason != "outOfRange" {
		t.Fatalf("limit: committed = %v, field = %q, reason = %q", committed, field, reason)
	}
	if _, err := os.Stat(filepath.Join(root, "remote")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused edit wrote the document: %v", err)
	}
}

// What closing a window does to the host's programs asks by default, is stored as the user
// chooses it and asks again once made automatic.
func TestClosingChoiceIsStoredAndRestored(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	read, err := ReadPreferences(ctx, kernel, t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if closing := read.State.Closing; closing.Source != core.RemotePreferenceAutomatic || closing.Programs != core.RemoteCloseAsk || closing.IdleTimeoutSeconds != 600 || read.State.Preferences.ClosePrograms != nil {
		t.Fatalf("automatic closing = %+v", closing)
	}
	keep := core.RemoteCloseKeep
	kept, committed, err := read.Edit(ctx, kernel, core.RemotePreferenceEdit{ClosePrograms: &core.RemoteCloseProgramsEdit{Programs: &keep}})
	if err != nil || !committed {
		t.Fatalf("keep: committed = %v, err = %v", committed, err)
	}
	stored := kept.State.Preferences.ClosePrograms
	if closing := kept.State.Closing; closing.Source != core.RemotePreferenceFromSetting || closing.Programs != core.RemoteCloseKeep || stored == nil || *stored != keep {
		t.Fatalf("kept closing = %+v", closing)
	}
	asked, committed, err := kept.Edit(ctx, kernel, core.RemotePreferenceEdit{ClosePrograms: &core.RemoteCloseProgramsEdit{}})
	if err != nil || !committed || asked.State.Closing.Source != core.RemotePreferenceAutomatic || asked.State.Closing.Programs != core.RemoteCloseAsk {
		t.Fatalf("automatic again: committed = %v, closing = %+v, err = %v", committed, asked.State.Closing, err)
	}
}

// A saved program that is executable takes effect; one that later disappears is reported, not
// treated as a damaged document.
func TestSavedProgramIsReportedWhenItDisappears(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the executable bit is Unix-only; Windows checks the file exists")
	}
	ctx := testContext(t)
	kernel := core.NewClient()
	root := t.TempDir()
	program := filepath.Join(t.TempDir(), "ssh")
	if err := os.WriteFile(program, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	read, err := ReadPreferences(ctx, kernel, root, "")
	if err != nil {
		t.Fatal(err)
	}
	saved, committed, err := read.Edit(ctx, kernel, core.RemotePreferenceEdit{SSHProgram: &core.RemoteSSHProgramEdit{Path: &program}})
	if err != nil || !committed {
		t.Fatalf("save: committed = %v, err = %v", committed, err)
	}
	ssh := saved.State.SSH
	if ssh.Source != core.RemotePreferenceFromSetting || ssh.Status != core.RemoteProgramFound || ssh.Path == nil || *ssh.Path != program {
		t.Fatalf("ssh = %+v", ssh)
	}
	if err := os.Remove(program); err != nil {
		t.Fatal(err)
	}
	reread, err := ReadPreferences(ctx, kernel, root, "")
	if err != nil || reread.State.SSH.Status != core.RemoteProgramMissing {
		t.Fatalf("status = %q, err = %v", reread.State.SSH.Status, err)
	}
}

// A document Core cannot decode is ErrDamaged: it still names its path, and PreferencesDocument
// refuses it, so nothing starts OpenSSH with it.
func TestDamagedPreferencesAreReported(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := t.TempDir()
	path := filepath.Join(root, "remote", "preferences.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"unknown":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	read, err := ReadPreferences(ctx, kernel, root, "")
	if !errors.Is(err, ErrDamaged) || read.Path() != path {
		t.Fatalf("read: path matches = %v, err = %v", read.Path() == path, err)
	}
	if _, err := PreferencesDocument(ctx, kernel, root); !errors.Is(err, ErrDamaged) {
		t.Fatalf("document: err = %v", err)
	}
	if _, err := ReadPreferences(ctx, kernel, "", ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("no root: err = %v", err)
	}
}
