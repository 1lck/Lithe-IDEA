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
