package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/app"
)

// corePreferencesLoader keeps the remote workspace preferences in a test directory through the
// real Core client, the way the workbench's adapter does.
type corePreferencesLoader struct {
	fakeToolchainLoader
	kernel     *core.Client
	root, home string
	saves      atomic.Int32
}

func newCorePreferencesLoader(t *testing.T) *corePreferencesLoader {
	t.Helper()
	return &corePreferencesLoader{kernel: core.NewClient(), root: filepath.Join(t.TempDir(), "preferences"), home: t.TempDir()}
}

func (l *corePreferencesLoader) LoadRemotePreferences(ctx context.Context) (RemotePreferences, error) {
	return l.read(ctx)
}

func (l *corePreferencesLoader) SaveRemotePreferences(ctx context.Context, prefs RemotePreferences, edits []core.RemotePreferenceEdit) (RemotePreferences, error) {
	l.saves.Add(1)
	saved := prefs.Saved
	for _, edit := range edits {
		var err error
		if saved, _, err = saved.Edit(ctx, l.kernel, edit); err != nil {
			return prefs, err
		}
	}
	return l.read(ctx)
}

func (l *corePreferencesLoader) read(ctx context.Context) (RemotePreferences, error) {
	automatic, err := l.kernel.RemotePreferences(ctx, nil, "")
	if err != nil {
		return RemotePreferences{}, err
	}
	saved, err := remoteconn.ReadPreferences(ctx, l.kernel, l.root, l.home)
	return RemotePreferences{Saved: saved, Automatic: automatic}, err
}

func (l *corePreferencesLoader) file() string {
	return filepath.Join(l.root, "remote", "preferences.json")
}

// remoteWorkspaceWindow opens a settings window on the Remote Workspace page and waits for the
// preferences to be read.
func remoteWorkspaceWindow(t *testing.T, loader *corePreferencesLoader) (*window, *windowDriver, *remotePreferencesState) {
	t.Helper()
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	w.sess.show(pageRemoteWorkspace)
	d := openWindow(t, w)
	r := w.toolchains.prefs
	d.until("the remote workspace preferences to load", func() bool { return (r.loaded || r.readFailed != nil) && !r.busy() })
	d.pump()
	return w, d, r
}

// Opening the page reads and creates nothing; it shows the automatic reconnect time Core resolves
// and the SSH configuration file it found missing.
func TestRemoteWorkspacePageOnlyReads(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	_, d, r := remoteWorkspaceWindow(t, loader)
	if r.readFailed != nil {
		t.Fatalf("read failed: %v", r.readFailed)
	}
	automatic := i18n.SharedFormat(i18n.English, "desktop.remoteSettings.reconnectAutomatic", map[string]string{
		"duration": remoteDuration(i18n.English, 60),
	})
	if !d.text(automatic) {
		t.Fatal("the reconnect row does not show the automatic time Core resolves")
	}
	if !d.has(filepath.Join(loader.home, ".ssh", "config")) || !d.text(en("desktop.remoteSettings.sshConfigMissing")) {
		t.Fatal("the SSH configuration row does not say the file is missing")
	}
	if _, err := os.Stat(loader.root); !os.IsNotExist(err) {
		t.Fatalf("opening the page created the preference directory: %v", err)
	}
	if r.drafts() != 0 || loader.saves.Load() != 0 {
		t.Fatalf("drafts = %d, saves = %d: opening the page changed something", r.drafts(), loader.saves.Load())
	}
}

// A changed reconnect time is a draft the footer's Apply writes; choosing Automatic again writes
// the file without it.
func TestRemoteWorkspaceReconnectLimitIsAppliedAndRestored(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	w, d, r := remoteWorkspaceWindow(t, loader)
	seconds := uint32(120)
	r.setLimit(&seconds)
	d.w.inv.Invalidate()
	d.pump()
	if r.drafts() != 1 {
		t.Fatalf("drafts = %d, want the reconnect time", r.drafts())
	}
	if _, err := os.Stat(loader.file()); !os.IsNotExist(err) {
		t.Fatalf("a draft wrote the file before Apply: %v", err)
	}
	d.click(en("desktop.buildSettings.apply"))
	d.until("the apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	if r.failed != nil || r.drafts() != 0 {
		t.Fatalf("failed = %v, drafts = %d", r.failed, r.drafts())
	}
	reconnect := r.source.Saved.State.Reconnect
	if reconnect.Source != core.RemotePreferenceFromSetting || reconnect.LimitSeconds != 120 {
		t.Fatalf("reconnect = %+v, want 120 seconds from the setting", reconnect)
	}
	text, err := os.ReadFile(loader.file())
	if err != nil || !strings.Contains(string(text), "120") {
		t.Fatalf("the file does not hold the time: err = %v", err)
	}
	if !d.text(remoteDuration(i18n.English, 120)) {
		t.Fatal("the row does not show the saved time")
	}

	r.setLimit(nil)
	d.w.inv.Invalidate()
	d.pump()
	d.click(en("desktop.buildSettings.apply"))
	d.until("the second apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	if got := r.source.Saved.State.Reconnect.Source; got != core.RemotePreferenceAutomatic || r.source.Saved.State.Preferences.ReconnectLimitSeconds != nil {
		t.Fatalf("source = %q: Automatic was not restored", got)
	}
}

// Core's refusal of a relative program names the field under the page and keeps the draft, and
// nothing is written.
func TestRemoteWorkspaceRefusedProgramKeepsTheDraft(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	w, d, r := remoteWorkspaceWindow(t, loader)
	relative := "bin/ssh"
	r.setProgram(&relative)
	d.w.inv.Invalidate()
	d.pump()
	d.click(en("desktop.buildSettings.apply"))
	d.until("the apply to stop", func() bool { return !w.apply.active() && !r.saving })
	d.until("the preferences to be read again", func() bool { return !r.busy() })
	d.pump()
	if r.failed == nil || r.drafts() != 1 {
		t.Fatalf("failed = %v, drafts = %d: the refusal did not keep the draft", r.failed, r.drafts())
	}
	if !d.wrapped(en("desktop.remoteSettings.refusedProgramRelative")) {
		t.Fatal("the page does not say the program must be an absolute path")
	}
	if _, err := os.Stat(loader.file()); !os.IsNotExist(err) {
		t.Fatalf("a refused edit wrote the file: %v", err)
	}
}

// A file Core cannot decode is reported with its path and nothing is offered to edit.
func TestRemoteWorkspaceDamagedFileIsReported(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	if err := os.MkdirAll(filepath.Dir(loader.file()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(loader.file(), []byte(`{"version":1,"unknown":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, d, r := remoteWorkspaceWindow(t, loader)
	message := i18n.SharedFormat(i18n.English, "desktop.remoteSettings.damaged", map[string]string{"path": loader.file()})
	if r.loaded || r.readFailed == nil || !d.wrapped(message) {
		t.Fatalf("loaded = %v, read failed = %v: the damaged file is not reported with its path", r.loaded, r.readFailed != nil)
	}
	if d.has(en("desktop.remoteSettings.sshProgram")) {
		t.Fatal("the page offers to edit a file it could not read")
	}
}

// Reverse forwarding is refused by Automatic, which the row says; allowing it is a draft Apply
// writes, after which Core reports it from the setting, and Automatic refuses it again.
func TestRemoteWorkspaceReverseForwardingIsAppliedAndRestored(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	w, d, r := remoteWorkspaceWindow(t, loader)
	automatic := i18n.SharedFormat(i18n.English, "desktop.remoteSettings.reverseAutomatic", map[string]string{
		"value": en("desktop.remoteSettings.reverseRefused"),
	})
	if r.source.Saved.State.Reverse.Allowed || !d.text(automatic) {
		t.Fatal("the reverse forwarding row does not show that Automatic refuses it")
	}
	allowed := true
	r.setReverse(&allowed)
	d.w.inv.Invalidate()
	d.pump()
	if r.drafts() != 1 {
		t.Fatalf("drafts = %d, want reverse forwarding", r.drafts())
	}
	if _, err := os.Stat(loader.file()); !os.IsNotExist(err) {
		t.Fatalf("a draft wrote the file before Apply: %v", err)
	}
	d.click(en("desktop.buildSettings.apply"))
	d.until("the apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	reverse := r.source.Saved.State.Reverse
	if r.failed != nil || r.drafts() != 0 || reverse.Source != core.RemotePreferenceFromSetting || !reverse.Allowed {
		t.Fatalf("failed = %v, drafts = %d, reverse = %+v, want it allowed by the setting", r.failed, r.drafts(), reverse)
	}
	if !d.text(en("desktop.remoteSettings.reverseAllowed")) {
		t.Fatal("the row does not show reverse forwarding allowed")
	}

	r.setReverse(nil)
	d.w.inv.Invalidate()
	d.pump()
	d.click(en("desktop.buildSettings.apply"))
	d.until("the second apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	if reverse := r.source.Saved.State.Reverse; reverse.Source != core.RemotePreferenceAutomatic || reverse.Allowed {
		t.Fatalf("reverse = %+v: Automatic was not restored", reverse)
	}
}

// The Closing card shows Automatic, which asks every time, and the host's idle timeout Core
// reports; choosing Keep on host is a draft Apply writes, and the row then shows the saved choice.
// Choosing Automatic again removes it from the file.
func TestRemoteWorkspaceClosingChoiceIsAppliedAndRestored(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	w, d, r := remoteWorkspaceWindow(t, loader)
	if !d.text(en("desktop.remoteSettings.closeAsk")) || !d.text(en("desktop.remoteSettings.closePrograms")) {
		t.Fatal("the closing row does not show that closing asks every time")
	}
	if !d.text(en("desktop.remoteSettings.idleTimeout")) || !d.text(remoteDuration(i18n.English, 600)) {
		t.Fatal("the idle timeout row does not show the host's ten minutes")
	}
	keep := core.RemoteCloseKeep
	r.setClosing(&keep)
	d.w.inv.Invalidate()
	d.pump()
	if r.drafts() != 1 {
		t.Fatalf("drafts = %d, want the closing choice", r.drafts())
	}
	d.click(en("desktop.buildSettings.apply"))
	d.until("the apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	closing := r.source.Saved.State.Closing
	if r.failed != nil || r.drafts() != 0 || closing.Source != core.RemotePreferenceFromSetting || closing.Programs != core.RemoteCloseKeep {
		t.Fatalf("failed = %v, drafts = %d, closing = %+v", r.failed, r.drafts(), closing)
	}
	if !d.text(en("desktop.remoteSettings.closeKeep")) {
		t.Fatal("the row does not show the saved choice")
	}

	r.setClosing(nil)
	d.w.inv.Invalidate()
	d.pump()
	d.click(en("desktop.buildSettings.apply"))
	d.until("the second apply to end", func() bool { return !w.apply.active() && !r.busy() })
	d.pump()
	if r.source.Saved.State.Preferences.ClosePrograms != nil || r.source.Saved.State.Closing.Programs != core.RemoteCloseAsk {
		t.Fatal("Automatic was not restored")
	}
}

// On Windows the native file dialog runs a modal message loop that can re-enter paint; running it
// via c.After keeps frame layout intact and still drafts the chosen SSH executable.
func TestRemoteProgramPickerRunsAfterPaint(t *testing.T) {
	loader := newCorePreferencesLoader(t)
	_, d, r := remoteWorkspaceWindow(t, loader)
	chosen := filepath.Join(t.TempDir(), "ssh")
	previous := openRemoteProgramFiles
	t.Cleanup(func() { openRemoteProgramFiles = previous })
	var called bool
	openRemoteProgramFiles = func(app.OpenFileOptions) ([]string, error) {
		called = true
		// Simulate a Windows modal dialog re-entering the window procedure mid-call.
		d.pump()
		return []string{chosen}, nil
	}
	d.click(en("desktop.remoteSettings.chooseProgram"))
	d.pump()
	if !called {
		t.Fatal("clicking Choose did not invoke the file picker")
	}
	if shown := r.shownProgram(); shown == nil || *shown != chosen {
		t.Fatalf("shownProgram = %v, want %q", shown, chosen)
	}
}
