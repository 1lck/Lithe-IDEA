package workbench

import (
	"context"
	"errors"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestSettingsSaveReturnsWhileDiskWriteIsBlocked(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	started, release := make(chan struct{}), make(chan struct{})
	h.app.settingsDiskWriter = func(disk *store.Store, next settings) (string, error) {
		close(started)
		<-release // The test owns the gate and releases it on every exit.
		return disk.SaveWithBackup(settingsFile, next)
	}
	returned := make(chan struct{})
	defer func() {
		close(release)
		awaitSettingsSave(t, returned, "setting callback cleanup")
	}()
	go func() {
		defer close(returned)
		h.app.setTerminalScrollback(3000)
	}()
	awaitSettingsSave(t, started, "uncontended settings write entered the writer")
	awaitSettingsSave(t, returned, "setting callback returned with disk write blocked")
}

func TestSettingsSaveCoalescesPendingWritesAndFlushesOnClose(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	started, release := make(chan struct{}), make(chan struct{})
	releaseFirst := sync.OnceFunc(func() { close(release) })
	defer releaseFirst()
	var writes []int
	h.app.settingsDiskWriter = func(disk *store.Store, next settings) (string, error) {
		writes = append(writes, next.TerminalScrollback)
		if len(writes) == 1 {
			close(started)
			<-release
		}
		return disk.SaveWithBackup(settingsFile, next)
	}
	h.app.setTerminalScrollback(3000)
	awaitSettingsSave(t, started, "first write reached disk")
	h.app.setTerminalScrollback(4000)
	h.app.setTerminalScrollback(5000)
	h.app.setTerminalScrollback(6000)

	allowed := false
	h.config.OnCloseRequest(func() { allowed = true })
	if allowed {
		t.Fatal("close proceeded before the last settings had reached disk")
	}
	releaseFirst()
	h.settle()
	if !allowed {
		t.Fatal("close did not proceed after the settings writer drained")
	}
	if !slices.Equal(writes, []int{3000, 6000}) {
		t.Fatalf("writes = %v, want the active write and the latest pending value", writes)
	}
	var saved settings
	if found, err := h.store.Load(settingsFile, &saved); err != nil || !found || saved.TerminalScrollback != 6000 {
		t.Fatalf("disk scrollback = %d, found = %v, error = %v; want 6000", saved.TerminalScrollback, found, err)
	}
}

func TestSettingsCloseKeepsLatestPreferencesAcrossTabs(t *testing.T) {
	for _, test := range []struct {
		name             string
		pending          bool
		closedDirectly   bool
		settingsSizeOnly bool
	}{
		{name: "workbench close during active save"},
		{name: "workbench close with a newer pending save", pending: true},
		{name: "direct window close", closedDirectly: true},
		{name: "settings window close with a newer pending save", pending: true, settingsSizeOnly: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h, alpha, beta := newTabsHarness(t)
			h.open(alpha)
			h.app.openProject(beta)
			s := h.app.sessions
			h.await("second project to open in its own tab", func() bool {
				return s.active != h.app && h.shownRoot() != ""
			})
			writerTab := s.active
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			for _, tab := range s.list {
				if err := tab.tasks.running.WaitContext(ctx); err != nil {
					t.Fatalf("waiting for project setup: %v", err)
				}
			}
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
			if !test.settingsSizeOnly {
				if err := h.driver.Resize(1600, 980); err != nil {
					t.Fatal(err)
				}
			}
			started, release := make(chan struct{}), make(chan struct{})
			releaseWrite := sync.OnceFunc(func() { close(release) })
			defer releaseWrite()
			writerTab.settingsDiskWriter = func(disk *store.Store, next settings) (string, error) {
				if next.TerminalScrollback == 3000 {
					close(started)
					<-release
				}
				return disk.SaveWithBackup(settingsFile, next)
			}

			writerTab.setTerminalScrollback(3000)
			awaitSettingsSave(t, started, "changed preference reached the blocked writer")
			wantScrollback := 3000
			if test.pending {
				wantScrollback = 6000
				writerTab.setTerminalScrollback(wantScrollback)
			}
			if h.app.settings.TerminalScrollback == wantScrollback {
				t.Fatal("the other tab must still hold the old preference")
			}

			allowed := false
			switch {
			case test.settingsSizeOnly:
				// Report the final size from the tab that owns the closing settings window.
				h.app.setSettingsWindowSize(1180, 820)
			case test.closedDirectly:
				s.activate(h.app)
				h.driver.Close()
			default:
				h.config.OnCloseRequest(func() { allowed = true })
				h.await("close request to reach the last tab with the writer blocked", func() bool {
					return len(s.list) == 1 && s.list[0] == h.app && h.app.project == nil
				})
				if allowed {
					t.Fatal("close proceeded with settings writes still blocked")
				}
			}

			idle := h.app.settingsPublication.settingsSaveIdle()
			releaseWrite()
			awaitSettingsSave(t, idle, "settings saved after closing")
			if !test.closedDirectly && !test.settingsSizeOnly {
				h.await("window close to finish after settings are saved", func() bool { return allowed })
			}
			var saved settings
			if found, err := h.store.Load(settingsFile, &saved); err != nil || !found {
				t.Fatalf("load saved settings: found=%v err=%v", found, err)
			}
			if saved.TerminalScrollback != wantScrollback {
				t.Errorf("saved scrollback = %d, want %d", saved.TerminalScrollback, wantScrollback)
			}
			if test.settingsSizeOnly {
				if saved.SettingsWindowWidth != 1180 || saved.SettingsWindowHeight != 820 {
					t.Errorf("saved settings window = %dx%d, want 1180x820", saved.SettingsWindowWidth, saved.SettingsWindowHeight)
				}
			} else if saved.WindowWidth != 1600 || saved.WindowHeight != 980 {
				t.Errorf("saved workbench window = %dx%d, want 1600x980", saved.WindowWidth, saved.WindowHeight)
			}
		})
	}
}

func TestSettingsCloseProceedsWhenFlushDeadlineExpires(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	log := &faultLog{}
	h.app.logSink = log
	started, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	h.app.settingsDiskWriter = func(disk *store.Store, next settings) (string, error) {
		close(started)
		<-release
		return disk.SaveWithBackup(settingsFile, next)
	}
	h.app.setTerminalScrollback(3000)
	awaitSettingsSave(t, started, "settings write entered the writer")
	allowed := false
	h.app.flushSettings(time.Nanosecond, func() { allowed = true })
	h.await("close to proceed while the timed-out write is still blocked", func() bool { return allowed })
	if _, operations := loggedStages(log); !slices.Contains(operations, shutdownWaitOperation) {
		t.Fatalf("settings flush timeout was not logged: %v", operations)
	}
}

func TestSettingsSaveReportsFailureAndAllowsLaterSave(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	log := &faultLog{}
	h.app.logSink = log
	writeErr := errors.New("settings write failed")
	h.app.settingsDiskWriter = func(*store.Store, settings) (string, error) {
		return "", writeErr
	}
	h.app.setTerminalScrollback(3000)
	h.settle()
	if !h.notified(h.app.text.Errors.SaveFailed(writeErr.Error())) {
		t.Fatal("the failed settings save was not reported to the window")
	}
	log.mu.Lock()
	logged := slices.ContainsFunc(log.events, func(event recordedEvent) bool {
		return event.event == operationFailedEvent && event.fields["operation"] == "settings_save"
	})
	log.mu.Unlock()
	if !logged {
		t.Fatal("the failed settings save was not logged")
	}

	h.app.settingsDiskWriter = nil
	h.app.setTerminalScrollback(4000)
	h.settle()
	var saved settings
	if _, err := h.store.Load(settingsFile, &saved); err != nil || saved.TerminalScrollback != 4000 {
		t.Fatalf("later save = %d, error = %v; want 4000", saved.TerminalScrollback, err)
	}
}

func TestNewProjectWindowReadsTheSavedOpenDestination(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	started, release := make(chan struct{}), make(chan struct{})
	releaseWrite := sync.OnceFunc(func() { close(release) })
	defer releaseWrite()
	h.app.settingsDiskWriter = func(disk *store.Store, next settings) (string, error) {
		close(started)
		<-release
		return disk.SaveWithBackup(settingsFile, next)
	}
	h.app.settings.ProjectOpenDestination = settingswindow.ProjectOpenNewWindow
	h.app.saveSettings()
	awaitSettingsSave(t, started, "remembered destination reached the writer")

	var found bool
	var err error
	var saved settings
	h.app.launchProjectWindow("project", func(string) error {
		found, err = store.At(h.store.Dir()).Load(settingsFile, &saved)
		return nil
	})
	releaseWrite()
	h.settle()
	if err != nil || !found || saved.ProjectOpenDestination != settingswindow.ProjectOpenNewWindow {
		t.Fatalf("new window read destination %q, found = %v, error = %v", saved.ProjectOpenDestination, found, err)
	}
}

func awaitSettingsSave(t *testing.T, done <-chan struct{}, action string) {
	t.Helper()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
		t.Fatalf("timed out waiting for %s", action)
	}
}
