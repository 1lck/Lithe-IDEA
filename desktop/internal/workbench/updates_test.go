package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	appupdate "github.com/vivaui/viva/update"
)

// fakeUpdateSource answers each check with the feed or the error the test set. A download
// returns archive at once, and a patch download returns patch or fails with patchErr; with
// nothing set, either reports a quarter of itself and holds until it is cancelled, which the
// test or the updater stopping with it does.
type fakeUpdateSource struct {
	mu       sync.Mutex
	feed     *appupdate.Feed
	err      error
	checks   int
	archive  string
	patch    string
	patchErr error
	// downloads and patchDownloads count the downloads of the full archive and of the patch.
	downloads, patchDownloads int
}

func (f *fakeUpdateSource) Check(context.Context) (*appupdate.Feed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.checks++
	return f.feed, f.err
}

func (f *fakeUpdateSource) Download(ctx context.Context, _ appupdate.Asset, _ string, progress func(done, total int64)) (string, error) {
	f.mu.Lock()
	f.downloads++
	archive := f.archive
	f.mu.Unlock()
	return heldDownload(ctx, archive, nil, progress)
}

func (f *fakeUpdateSource) DownloadPatch(ctx context.Context, _ appupdate.Asset, _ appupdate.Patch, _ string, progress func(done, total int64)) (string, error) {
	f.mu.Lock()
	f.patchDownloads++
	patch, err := f.patch, f.patchErr
	f.mu.Unlock()
	return heldDownload(ctx, patch, err, progress)
}

// heldDownload fails with err, returns path whole, or with neither reports a quarter and
// waits for ctx to be cancelled.
func heldDownload(ctx context.Context, path string, err error, progress func(done, total int64)) (string, error) {
	switch {
	case err != nil:
		return "", err
	case path != "":
		progress(1, 1)
		return path, nil
	}
	progress(1, 4)
	<-ctx.Done()
	return "", ctx.Err()
}

func (f *fakeUpdateSource) checkCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.checks
}

// downloadCounts are how often the full archive and the patch were downloaded.
func (f *fakeUpdateSource) downloadCounts() (full, patch int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.downloads, f.patchDownloads
}

// offer makes the next check find feed.
func (f *fakeUpdateSource) offer(feed *appupdate.Feed) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.feed = feed
}

// updateFeed is a feed offering version with an archive for this platform.
func updateFeed(version string) *appupdate.Feed {
	return &appupdate.Feed{App: buildinfo.UpdateApp, Latest: appupdate.Release{Version: version, Assets: []appupdate.Asset{{
		OS: runtime.GOOS, Arch: runtime.GOARCH, Format: appupdate.FormatZIP,
		URL: "https://example.invalid/lithe.zip", Size: 4, SHA256: strings.Repeat("0", 64),
	}}}}
}

// deltaFeed is updateFeed with a 2-byte patch from the version from.
func deltaFeed(version, from string) *appupdate.Feed {
	feed := updateFeed(version)
	feed.Latest.Assets[0].Patches = []appupdate.Patch{{
		FromVersion: from, URL: "https://example.invalid/lithe.patch", Size: 2, SHA256: strings.Repeat("1", 64),
	}}
	return feed
}

// fakeInstaller stands in for applying a patch, the installer and the window's Quit. apply
// rebuilds into a new directory unless applyErr is set. install records what it was handed,
// fails a payload with payloadErr and an archive with archiveErr, and otherwise quits the way
// the real one does.
type fakeInstaller struct {
	mu                               sync.Mutex
	dir                              string
	applyErr, payloadErr, archiveErr error
	applied                          []string
	payloads                         []string
	installs                         []appupdate.InstallOptions
	// present says, per install, whether the payload it was handed still existed.
	present []bool
	quits   int
}

// installFakes replaces the patch applier, the installer, Quit and the cache directory for
// the test, restoring them after it.
func installFakes(t *testing.T) *fakeInstaller {
	t.Helper()
	f := &fakeInstaller{dir: t.TempDir()}
	cache := t.TempDir()
	apply, install, quit, cacheDir, remove := applyUpdatePatch, installUpdateArchive, updateQuit, updateCacheDir, removeUpdateDir
	t.Cleanup(func() {
		applyUpdatePatch, installUpdateArchive, updateQuit, updateCacheDir, removeUpdateDir = apply, install, quit, cacheDir, remove
	})
	applyUpdatePatch = f.apply
	installUpdateArchive = f.install
	updateQuit = func(*App) func() { return f.quit }
	updateCacheDir = func() (string, error) { return cache, nil }
	return f
}

func (f *fakeInstaller) apply(_, _, from, to string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.applied = append(f.applied, from+" → "+to)
	if f.applyErr != nil {
		return "", f.applyErr
	}
	payload, err := os.MkdirTemp(f.dir, "payload-")
	if err != nil {
		return "", err
	}
	f.payloads = append(f.payloads, payload)
	return payload, nil
}

func (f *fakeInstaller) install(options appupdate.InstallOptions, quit func()) error {
	f.mu.Lock()
	f.installs = append(f.installs, options)
	_, statErr := os.Stat(options.Payload)
	f.present = append(f.present, statErr == nil)
	err := f.archiveErr
	if options.Payload != "" {
		err = f.payloadErr
	}
	f.mu.Unlock()
	if err != nil {
		return err
	}
	quit()
	return nil
}

func (f *fakeInstaller) quit() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.quits++
}

// state is a copy of what the fakes were asked to do.
func (f *fakeInstaller) state() (applied, payloads []string, installs []appupdate.InstallOptions, present []bool, quits int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.applied), slices.Clone(f.payloads), slices.Clone(f.installs), slices.Clone(f.present), f.quits
}

// updateFile is a file standing for a verified download.
func updateFile(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte("lithe"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// newDeltaHarness is a window running version 0.7.0, whose updater reads source and whose
// log records what the update logs.
func newDeltaHarness(t *testing.T, source *fakeUpdateSource) (*harness, *treeRecordingLog) {
	t.Helper()
	h := newUpdateHarness(t, source)
	h.app.version = "0.7.0"
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	return h, logger
}

// loggedEvents are the events named event the log recorded.
func loggedEvents(logger *treeRecordingLog, event string) []core.LogEvent {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var found []core.LogEvent
	for _, logged := range logger.events {
		if logged.Event == event {
			found = append(found, logged)
		}
	}
	return found
}

// gone reports whether nothing is left at path.
func gone(path string) bool {
	_, err := os.Stat(path)
	return errors.Is(err, os.ErrNotExist)
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

// TestDeltaUpdateInstallsTheRebuiltApplication offers a patch from the running version: the
// row says so with both sizes, Update downloads the patch rather than the archive, rebuilds
// the application from 0.7.0 to 0.8.0 and installs that copy, which is deleted once the
// installer has it.
func TestDeltaUpdateInstallsTheRebuiltApplication(t *testing.T) {
	fakes := installFakes(t)
	source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0"), patch: updateFile(t, "lithe.patch")}
	h, logger := newDeltaHarness(t, source)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	if status := a.updateStatus(); !status.Delta || status.DeltaSize != 2 || status.FullSize != 4 {
		t.Fatalf("the check found %+v, want the 2-byte patch offered next to the 4-byte archive", status)
	}

	a.updateNow()
	h.await("the install", func() bool { _, _, _, _, quits := fakes.state(); return quits == 1 })
	// The copy is deleted in the background.
	a.wait()
	applied, payloads, installs, present, _ := fakes.state()
	if len(applied) != 1 || applied[0] != "0.7.0 → 0.8.0" || len(payloads) != 1 {
		t.Fatalf("applied %v into %v, want one patch from 0.7.0 to 0.8.0", applied, payloads)
	}
	if len(installs) != 1 || installs[0].Payload != payloads[0] || installs[0].Artifact != "" || installs[0].Version != "0.8.0" || !present[0] {
		t.Fatalf("installed %+v (payload present %v), want the rebuilt copy of 0.8.0 and no archive", installs, present)
	}
	if !gone(payloads[0]) {
		t.Fatalf("the rebuilt copy %s is still there after the installer took it", payloads[0])
	}
	if full, patch := source.downloadCounts(); full != 0 || patch != 1 {
		t.Fatalf("downloaded the archive %d times and the patch %d times, want only the patch", full, patch)
	}
	if events := loggedEvents(logger, deltaFallbackEvent); len(events) != 0 {
		t.Fatalf("logged a fallback %v for a patch that worked", events)
	}
}

// TestDeltaUpdateFallsBackToTheFullArchive fails each step of a delta update in turn: Update
// logs the step and why at warn, downloads the full archive and installs it, deletes a copy
// the patch rebuilt, and the next check offers the archive alone for that version. The
// archive's install is made to fail so the window stays for that check.
func TestDeltaUpdateFallsBackToTheFullArchive(t *testing.T) {
	for _, tc := range []struct {
		stage string
		fail  func(*fakeUpdateSource, *fakeInstaller)
	}{
		{deltaStageDownload, func(s *fakeUpdateSource, _ *fakeInstaller) { s.patchErr = errors.New("patch unreachable") }},
		{deltaStageApply, func(_ *fakeUpdateSource, f *fakeInstaller) { f.applyErr = errors.New("patch does not apply") }},
		{deltaStageInstall, func(_ *fakeUpdateSource, f *fakeInstaller) {
			f.payloadErr = fmt.Errorf("%w: rebuilt bundle", appupdate.ErrUntrusted)
		}},
	} {
		t.Run(tc.stage, func(t *testing.T) {
			fakes := installFakes(t)
			fakes.archiveErr = errors.New("archive install stopped by the test")
			source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0"), patch: updateFile(t, "lithe.patch"), archive: updateFile(t, "lithe.zip")}
			tc.fail(source, fakes)
			h, logger := newDeltaHarness(t, source)
			a := h.app

			a.checkForUpdates(true)
			h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
			a.updateNow()
			h.await("the archive's install", func() bool { return a.updateStatus().Failure != "" })
			a.wait()
			_, payloads, installs, _, _ := fakes.state()
			if len(installs) == 0 || installs[len(installs)-1].Artifact != source.archive || installs[len(installs)-1].Payload != "" {
				t.Fatalf("installed %+v, want the full archive last", installs)
			}
			if full, _ := source.downloadCounts(); full != 1 {
				t.Fatalf("downloaded the full archive %d times, want once", full)
			}
			events := loggedEvents(logger, deltaFallbackEvent)
			if len(events) != 1 || events[0].Level != core.LevelWarn || events[0].Fields["stage"] != tc.stage || events[0].Fields["error"] == nil {
				t.Fatalf("logged %+v, want one warn naming the %s step and its error", events, tc.stage)
			}
			for _, payload := range payloads {
				if !gone(payload) {
					t.Fatalf("the rebuilt copy %s is still there after its install failed", payload)
				}
			}

			a.checkForUpdates(true)
			h.await("the next check", func() bool { return !a.updateStatus().Checking })
			if status := a.updateStatus(); status.Delta || status.Available != "0.8.0" {
				t.Fatalf("after the fallback the check found %+v, want 0.8.0 offered in full", status)
			}
		})
	}
}

// TestDeltaUpdateRefusalIsNotRetriedInFull installs a rebuilt copy into an application that
// cannot be replaced: the full archive would meet the same refusal, so Update says why it
// failed and downloads nothing more, and the copy is deleted.
func TestDeltaUpdateRefusalIsNotRetriedInFull(t *testing.T) {
	fakes := installFakes(t)
	fakes.payloadErr = fmt.Errorf("%w: read-only volume", appupdate.ErrNotWritable)
	source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0"), patch: updateFile(t, "lithe.patch"), archive: updateFile(t, "lithe.zip")}
	h, logger := newDeltaHarness(t, source)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	a.updateNow()
	h.await("the refusal", func() bool { return a.updateStatus().Failure != "" })
	a.wait()
	if full, _ := source.downloadCounts(); full != 0 {
		t.Fatalf("downloaded the full archive %d times after a refusal it would meet too", full)
	}
	if events := loggedEvents(logger, deltaFallbackEvent); len(events) != 0 {
		t.Fatalf("logged a fallback %v for a refusal", events)
	}
	if events := loggedEvents(logger, operationFailedEvent); len(events) != 1 {
		t.Fatalf("logged the failure %d times, want once", len(events))
	}
	_, payloads, _, _, _ := fakes.state()
	if len(payloads) != 1 || !gone(payloads[0]) {
		t.Fatalf("rebuilt %v, want one copy, deleted after the refusal", payloads)
	}
	if status := a.updateStatus(); status.Ready || status.Installing {
		t.Fatalf("after the refusal the status is %+v, want nothing waiting to install", status)
	}
}

// TestCancelledPatchDownloadIsNotAFallback cancels Update while the patch downloads: the row
// offers the delta update again, nothing failed, and the full archive is not fetched.
func TestCancelledPatchDownloadIsNotAFallback(t *testing.T) {
	installFakes(t)
	source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0")}
	h, logger := newDeltaHarness(t, source)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	a.updateNow()
	h.await("the patch's progress", func() bool {
		status := a.updateStatus()
		return status.Downloading && status.Delta && status.Progress == 0.25
	})
	a.cancelUpdate()
	h.await("the cancelled download", func() bool { return !a.updateStatus().Downloading })
	if status := a.updateStatus(); status.Failure != "" || status.Ready || !status.Delta || status.FellBack {
		t.Fatalf("after Cancel the status is %+v, want the delta update offered again and no failure", status)
	}
	if full, _ := source.downloadCounts(); full != 0 {
		t.Fatalf("downloaded the full archive %d times after a cancel", full)
	}
	if events := loggedEvents(logger, deltaFallbackEvent); len(events) != 0 {
		t.Fatalf("logged a fallback %v for a cancel", events)
	}
}

// TestRebuiltApplicationIsDeletedWhenNothingWillInstallIt rebuilds 0.8.0 and leaves it
// waiting, as when a window has no Quit to install with: a check finding another version
// deletes it and no longer says it is ready, the window closing deletes it, and a deletion
// that fails is logged.
func TestRebuiltApplicationIsDeletedWhenNothingWillInstallIt(t *testing.T) {
	for _, tc := range []struct {
		name      string
		removeErr error
		end       func(*testing.T, *harness, *fakeUpdateSource)
	}{
		{"another version", nil, func(t *testing.T, h *harness, source *fakeUpdateSource) {
			source.offer(deltaFeed("0.9.0", "0.7.0"))
			h.app.checkForUpdates(true)
			h.await("the next check", func() bool { return h.app.updateStatus().Available == "0.9.0" })
			if h.app.updateStatus().Ready {
				t.Fatal("Update still says a version is ready to install after the check found another")
			}
		}},
		{"the window closes", nil, func(_ *testing.T, h *harness, _ *fakeUpdateSource) { h.app.stopUpdates() }},
		{"the deletion fails", errors.New("directory busy"), func(_ *testing.T, h *harness, _ *fakeUpdateSource) { h.app.stopUpdates() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fakes := installFakes(t)
			// No Quit stands for a window that cannot install now.
			updateQuit = func(*App) func() { return nil }
			if tc.removeErr != nil {
				removeUpdateDir = func(string) error { return tc.removeErr }
			}
			source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0"), patch: updateFile(t, "lithe.patch")}
			h, logger := newDeltaHarness(t, source)
			a := h.app

			a.checkForUpdates(true)
			h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
			a.updateNow()
			h.await("the rebuilt copy", func() bool {
				status := a.updateStatus()
				return status.Ready && !status.Downloading
			})
			_, payloads, _, _, _ := fakes.state()
			if len(payloads) != 1 || gone(payloads[0]) {
				t.Fatalf("rebuilt %v, want one copy waiting", payloads)
			}

			tc.end(t, h, source)
			a.wait()
			failures := loggedEvents(logger, deltaCleanupFailedEvent)
			if tc.removeErr != nil {
				if len(failures) != 1 || failures[0].Level != core.LevelWarn || failures[0].Fields["error"] == nil {
					t.Fatalf("logged %+v, want one warn with the deletion's error", failures)
				}
				return
			}
			if !gone(payloads[0]) || len(failures) != 0 {
				t.Fatalf("the copy is gone = %v and %d deletions failed, want it deleted", gone(payloads[0]), len(failures))
			}
		})
	}
}

// TestRebuiltApplicationIsDeletedOffTheWindowThread holds the deletion of a rebuilt copy that
// a check found another version for: the check shows its result while the deletion is held,
// because the window thread does not wait for it, and the copy goes once it is let through.
func TestRebuiltApplicationIsDeletedOffTheWindowThread(t *testing.T) {
	fakes := installFakes(t)
	updateQuit = func(*App) func() { return nil }
	started, release := make(chan struct{}, 1), make(chan struct{})
	var once sync.Once
	let := func() { once.Do(func() { close(release) }) }
	removeUpdateDir = func(path string) error {
		select {
		case started <- struct{}{}:
		default:
		}
		// The bound only matters if the deletion runs on the window thread, which it would
		// hold; the copy is then gone before the check shows its result, and the test fails.
		held := time.NewTimer(8 * time.Second)
		defer held.Stop()
		select {
		case <-release:
		case <-held.C:
		}
		return os.RemoveAll(path)
	}
	source := &fakeUpdateSource{feed: deltaFeed("0.8.0", "0.7.0"), patch: updateFile(t, "lithe.patch")}
	h, _ := newDeltaHarness(t, source)
	// Registered after the harness, so a test that fails early lets the deletion through
	// before the harness stops.
	t.Cleanup(let)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	a.updateNow()
	h.await("the rebuilt copy", func() bool {
		status := a.updateStatus()
		return status.Ready && !status.Downloading
	})
	_, payloads, _, _, _ := fakes.state()
	if len(payloads) != 1 {
		t.Fatalf("rebuilt %v, want one copy waiting", payloads)
	}

	source.offer(deltaFeed("0.9.0", "0.7.0"))
	a.checkForUpdates(true)
	h.await("the next check", func() bool { return a.updateStatus().Available == "0.9.0" })
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	select {
	case <-started:
	case <-deadline.C:
		t.Fatal("the check found another version but the rebuilt copy was never deleted")
	}
	if gone(payloads[0]) {
		t.Fatal("the rebuilt copy was deleted before the check showed its result, so the window thread waited for it")
	}
	let()
	a.wait()
	if !gone(payloads[0]) {
		t.Fatalf("the rebuilt copy %s is still there after its deletion was let through", payloads[0])
	}
}
