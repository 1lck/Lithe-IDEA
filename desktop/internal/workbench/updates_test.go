package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	appupdate "github.com/vivaui/viva/update"
)

// fakeUpdateSource answers each check with the feed or the error the test set, and holds a
// download, after reporting a quarter of it, until the download is cancelled.
type fakeUpdateSource struct {
	mu     sync.Mutex
	feed   *appupdate.Feed
	err    error
	checks int
}

func (f *fakeUpdateSource) Check(context.Context) (*appupdate.Feed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.checks++
	return f.feed, f.err
}

func (f *fakeUpdateSource) Download(ctx context.Context, _ appupdate.Asset, _ string, progress func(done, total int64)) (string, error) {
	progress(1, 4)
	<-ctx.Done()
	return "", ctx.Err()
}

func (f *fakeUpdateSource) checkCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.checks
}

// updateFeed is a feed offering version with an archive for this platform.
func updateFeed(version string) *appupdate.Feed {
	return &appupdate.Feed{App: buildinfo.UpdateApp, Latest: appupdate.Release{Version: version, Assets: []appupdate.Asset{{
		OS: runtime.GOOS, Arch: runtime.GOARCH, Format: appupdate.FormatZIP,
		URL: "https://example.invalid/lithe.zip", Size: 4, SHA256: strings.Repeat("0", 64),
	}}}}
}

// newUpdateHarness is a window whose updater reads source. The updater is stopped with the
// test, so no check stays armed and a held download ends.
func newUpdateHarness(t *testing.T, source *fakeUpdateSource) *harness {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	u := h.app.updates
	u.mu.Lock()
	u.source = source
	u.mu.Unlock()
	t.Cleanup(h.app.stopUpdates)
	return h
}

// savedSettings reads the settings file afresh, so a field the file leaves out reads as unset.
func savedSettings(t *testing.T, h *harness) settings {
	t.Helper()
	var saved settings
	if _, err := h.store.Load(settingsFile, &saved); err != nil {
		t.Fatalf("read the saved settings: %v", err)
	}
	return saved
}

// noticeCount is how often the window said message.
func noticeCount(a *App, message string) int {
	for _, entry := range a.notifications.list {
		if entry.text == message {
			return entry.count
		}
	}
	return 0
}

// TestAutomaticUpdateCheckWaitsForTheWindowAndAnnouncesOnce walks Motty's automatic check: a
// check that comes due while the window is in the background waits, runs when the window is
// active again, says in a notice that a version is available, saves when it read the feed and
// arms the next check; the next check finding the same version says nothing again.
func TestAutomaticUpdateCheckWaitsForTheWindowAndAnnouncesOnce(t *testing.T) {
	source := &fakeUpdateSource{feed: updateFeed("0.8.0")}
	h := newUpdateHarness(t, source)
	a := h.app

	a.windowInactive = true
	a.updateCheckDue()
	if source.checkCount() != 0 || !a.updates.deferred {
		t.Fatalf("a check due in the background ran %d times, deferred = %v; want it kept for later", source.checkCount(), a.updates.deferred)
	}

	a.windowInactive = false
	a.resumeUpdateCheck()
	h.await("the deferred check", func() bool { return a.updateStatus().Available == "0.8.0" })
	notice := a.text.Updates.Available("0.8.0")
	if n := noticeCount(a, notice); n != 1 {
		t.Fatalf("the notice came %d times, want once", n)
	}
	if a.updates.timer == nil {
		t.Fatal("no next check is armed after the automatic check")
	}
	if saved := savedSettings(t, h); saved.UpdatesCheckedAt.IsZero() || saved.UpdatesManual {
		t.Fatalf("saved checked at %v, manual = %v; want the time of the check with the automatic check on", saved.UpdatesCheckedAt, saved.UpdatesManual)
	}

	a.updateCheckDue()
	h.await("the next check", func() bool { return source.checkCount() == 2 && !a.updateStatus().Checking })
	if n := noticeCount(a, notice); n != 1 {
		t.Fatalf("the same version was announced %d times, want once", n)
	}
}

// TestUpdateCheckFailureShowsOnlyWhenAsked fails the feed: a check nobody asked for says
// nothing on the page, and Check Now says why it failed.
func TestUpdateCheckFailureShowsOnlyWhenAsked(t *testing.T) {
	source := &fakeUpdateSource{err: errors.New("feed unreachable")}
	h := newUpdateHarness(t, source)
	a := h.app

	a.updateCheckDue()
	h.await("the automatic check", func() bool { return source.checkCount() == 1 && !a.updateStatus().Checking })
	if status := a.updateStatus(); status.Failure != "" {
		t.Fatalf("the automatic check showed %q, want nothing", status.Failure)
	}

	a.checkForUpdates(true)
	h.await("the asked check", func() bool { return a.updateStatus().Failure == "feed unreachable" })
}

// TestCancelledUpdateDownloadPutsTheRowBack starts Update, which downloads into the user's
// cache directory with its progress shown, and cancels it: the row offers the version again
// and says nothing failed.
func TestCancelledUpdateDownloadPutsTheRowBack(t *testing.T) {
	cache := t.TempDir()
	saved := updateCacheDir
	updateCacheDir = func() (string, error) { return cache, nil }
	t.Cleanup(func() { updateCacheDir = saved })
	source := &fakeUpdateSource{feed: updateFeed("0.8.0")}
	h := newUpdateHarness(t, source)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	a.updateNow()
	h.await("the download's progress", func() bool {
		status := a.updateStatus()
		return status.Downloading && status.Progress == 0.25
	})
	if info, err := os.Stat(filepath.Join(cache, "Lithe", "Updates", "0.8.0")); err != nil || !info.IsDir() {
		t.Fatalf("the download directory is %v (%v), want it in the cache directory", info, err)
	}

	a.cancelUpdate()
	h.await("the cancelled download", func() bool { return !a.updateStatus().Downloading })
	if status := a.updateStatus(); status.Failure != "" || status.Ready || status.Progress != 0 || status.Available != "0.8.0" {
		t.Fatalf("after Cancel the status is %+v, want the version offered again and no failure", status)
	}
}

// TestTurningOffTheAutomaticCheckDisarmsAndSavesIt turns the automatic check off, which
// disarms the next check and is saved, and on again, which arms it.
func TestTurningOffTheAutomaticCheckDisarmsAndSavesIt(t *testing.T) {
	h := newUpdateHarness(t, &fakeUpdateSource{})
	a := h.app
	a.scheduleUpdateCheck(a.updates.every)
	if a.updates.timer == nil {
		t.Fatal("no check is armed with the automatic check on")
	}

	a.setAutoCheckUpdates(false)
	if manual := savedSettings(t, h).UpdatesManual; !manual || a.updates.timer != nil || a.autoCheckUpdates() {
		t.Fatalf("after turning it off: saved manual = %v, armed = %v; want it saved off and nothing armed", manual, a.updates.timer != nil)
	}

	a.setAutoCheckUpdates(true)
	if manual := savedSettings(t, h).UpdatesManual; manual || a.updates.timer == nil {
		t.Fatalf("after turning it on: saved manual = %v, armed = %v; want it saved on and the first check armed", manual, a.updates.timer != nil)
	}
}
