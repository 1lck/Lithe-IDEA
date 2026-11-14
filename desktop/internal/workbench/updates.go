package workbench

import (
	"context"
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	appupdate "github.com/vivaui/viva/update"
)

// Updates come from the signed feed a release build names (buildinfo.UpdateFeedURL): Viva's
// update package checks the Ed25519 signature, downloads the archive for this platform with
// its size and SHA-256 checked, and installs it, keeping the old application until the new
// one starts. The download lands in the user's cache directory, never in the installed
// application.
//
// When the feed lists a patch from the running version, Update downloads that instead, as
// Sparkle's delta updates did on the old macOS client. The patch is checked like the archive.
// Viva rebuilds the new application from the installed one in a temporary directory
// (update.ApplyPatch): it reads the installed application and never writes into it. The
// rebuilt copy is installed with the same checks as an unpacked archive. Viva makes patches
// for macOS and Linux only, and a Windows feed lists none, so Windows always downloads the
// full installer. If the patch cannot be downloaded, applied or installed, Update logs why
// (update.delta.fallback_selected) and downloads the full archive. It skips the patch for
// that version from then on. A refusal the full archive would meet too is not retried: an
// application its package manager updates, or one that cannot be replaced.
//
// The rebuilt copy is used once. It is deleted when the installer has copied it, when an
// install with it fails, when a check finds another version, and when the window closes; a
// deletion that fails is logged (update.delta.cleanup_failed).
//
// The checks are Motty's. With the automatic check on, the first runs updateFirstCheck after
// launch and each next one updateCheckInterval after the one before. A check that comes due
// while the window is in the background waits until the window is active again, so an idle
// Lithe does not read the feed every hour for nobody. A check nobody asked for says only that
// a version is available, once per version, in a notice: it never opens anything over what
// the user is doing, and it says nothing when it fails, which the log records. Update, in
// Settings > About and Settings > Updates, downloads and verifies the version, then installs
// it and restarts; while it downloads, Cancel stops it.

const (
	// updateFirstCheck is how long after launch the first automatic check runs, late enough
	// not to compete with opening the project.
	updateFirstCheck = 5 * time.Second
	// updateCheckInterval is the time between automatic checks.
	updateCheckInterval = time.Hour
	// updateCheckTimeout bounds one read of the feed.
	updateCheckTimeout = time.Minute
)

// The events a delta update logs, which Core's catalog declares (rust/logging/events/update.json).
const (
	deltaFallbackEvent      = "update.delta.fallback_selected"
	deltaCleanupFailedEvent = "update.delta.cleanup_failed"
)

// The step of a delta update that failed, as update.delta.fallback_selected names it.
const (
	deltaStageDownload = "download"
	deltaStageApply    = "apply"
	deltaStageInstall  = "install"
)

// updateSource reads the feed and downloads a release or a patch to it: *appupdate.Client,
// or a test's.
type updateSource interface {
	Check(ctx context.Context) (*appupdate.Feed, error)
	Download(ctx context.Context, asset appupdate.Asset, dir string, progress func(done, total int64)) (string, error)
	DownloadPatch(ctx context.Context, asset appupdate.Asset, patch appupdate.Patch, dir string, progress func(done, total int64)) (string, error)
}

// installUpdateArchive replaces the application with a verified download or a rebuilt copy
// and restarts it; a test replaces it.
var installUpdateArchive = appupdate.Install

// applyUpdatePatch rebuilds the new application from the installed one and a verified patch
// in a temporary directory, returning that directory; a test replaces it.
var applyUpdatePatch = appupdate.ApplyPatch

// updateQuit is what an install calls to end the running application once the new one is in
// place: the application's Quit, or nil in a window without one. A test replaces it.
var updateQuit = func(a *App) func() {
	if a.application == nil {
		return nil
	}
	return a.application.Quit
}

// updateCacheDir is the user's cache directory, which downloads go under; a test replaces it.
var updateCacheDir = os.UserCacheDir

// removeUpdateDir deletes the application a patch rebuilt; a test makes it fail.
var removeUpdateDir = os.RemoveAll

// updater is the update state of the window, which every project tab of it shares: the
// window has one application to update and one setting for checking. The settings windows
// read the status from their own threads, so it and what the steps found are behind mu; the
// fields after them belong to the window thread.
type updater struct {
	mu       sync.Mutex
	status   settingswindow.UpdateStatus
	source   updateSource
	feed     *appupdate.Feed
	asset    appupdate.Asset
	artifact string
	// payload is the application a patch rebuilt in the temporary directory, waiting to be
	// installed; at most one of it and artifact is set.
	payload string
	// noDelta is the version whose patch failed, which Update downloads in full from then on.
	noDelta string
	cancel  context.CancelFunc

	// auto says Lithe checks on its own, and checkedAt is when a check last read the feed;
	// both are saved with the settings.
	auto      bool
	checkedAt time.Time
	// timer is the next automatic check, and deferred says one came due while the window
	// was in the background. stopped says the window closed, after which nothing is armed.
	timer    *time.Timer
	deferred bool
	stopped  bool
	// announced is the last version a notice told about.
	announced string
	// first and every are updateFirstCheck and updateCheckInterval; a test shortens them.
	first, every time.Duration
}

// newUpdater is the updater of a new window, with the stored setting and last check.
func newUpdater(stored settings) *updater {
	u := &updater{auto: !stored.UpdatesManual, checkedAt: stored.UpdatesCheckedAt, first: updateFirstCheck, every: updateCheckInterval}
	u.status.LastChecked = stored.UpdatesCheckedAt
	return u
}

// store writes the update setting and the last check into the settings being saved, so
// whichever tab saves, it saves the window's.
func (u *updater) store(into *settings) {
	if u == nil {
		return
	}
	into.UpdatesManual, into.UpdatesCheckedAt = !u.auto, u.checkedAt
}

// newUpdateClient is the feed client of this build, nil when the build names no feed.
func newUpdateClient(current string) *appupdate.Client {
	if buildinfo.UpdateFeedURL == "" || buildinfo.UpdatePublicKeys == "" || current == "" {
		return nil
	}
	var keys []ed25519.PublicKey
	for _, text := range strings.Split(buildinfo.UpdatePublicKeys, ",") {
		if key, err := appupdate.ParsePublicKey(strings.TrimSpace(text)); err == nil {
			keys = append(keys, key)
		}
	}
	if len(keys) == 0 {
		return nil
	}
	client, err := appupdate.New(appupdate.Config{
		FeedURL: buildinfo.UpdateFeedURL, PublicKeys: keys,
		App: buildinfo.UpdateApp, Channel: buildinfo.UpdateChannel, Current: current,
	})
	if err != nil {
		return nil
	}
	return client
}

// updateStatus is a copy of the status for the settings window.
func (a *App) updateStatus() settingswindow.UpdateStatus {
	u := a.updates
	u.mu.Lock()
	defer u.mu.Unlock()
	status := u.status
	status.Configured = u.source != nil
	return status
}

// changeUpdate edits the status under the lock and repaints the settings window of every
// tab, which all show it.
func (a *App) changeUpdate(change func(*settingswindow.UpdateStatus)) {
	u := a.updates
	u.mu.Lock()
	change(&u.status)
	u.mu.Unlock()
	for _, tab := range a.everyTab() {
		if tab.settingsWindow != nil {
			tab.settingsWindow.Invalidate()
		}
	}
}

// everyTab is every workbench of the window, open or retired, or a alone without one.
func (a *App) everyTab() []*App {
	if tabs := a.sessions.everyOne(); len(tabs) > 0 {
		return tabs
	}
	return []*App{a}
}

// shownTab is the workbench the window shows, which a notice has to land on to be seen.
func (a *App) shownTab() *App {
	if s := a.sessions; s != nil && s.active != nil {
		return s.active
	}
	return a
}

// startUpdates makes the feed client and, when the automatic check is on, arms the first.
func (a *App) startUpdates() {
	if client := newUpdateClient(a.version); client != nil {
		a.updates.mu.Lock()
		a.updates.source = client
		a.updates.mu.Unlock()
	}
	a.scheduleUpdateCheck(a.updates.first)
}

// autoCheckUpdates is the setting, on unless the user turned it off.
func (a *App) autoCheckUpdates() bool { return a.updates.auto }

// setAutoCheckUpdates turns the automatic check on, arming the first one, or off.
func (a *App) setAutoCheckUpdates(on bool) {
	u := a.updates
	if u.auto == on {
		return
	}
	u.auto = on
	if on {
		a.scheduleUpdateCheck(u.first)
	} else {
		a.stopUpdateCheck()
	}
	a.saveSettings()
}

// scheduleUpdateCheck arms the automatic check to come due after delay. It is the only
// thing that starts a check without the user, and it stops the armed one first, so there
// is never more than one.
func (a *App) scheduleUpdateCheck(delay time.Duration) {
	u := a.updates
	a.stopUpdateCheck()
	u.mu.Lock()
	configured := u.source != nil
	u.mu.Unlock()
	if u.stopped || !u.auto || !configured {
		return
	}
	var timer *time.Timer
	timer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			// A timer stopped after it fired still delivers: only the armed one counts.
			if a.updates.timer == timer {
				a.updates.timer = nil
				a.updateCheckDue()
			}
		})
	})
	u.timer = timer
}

// stopUpdateCheck disarms the automatic check and forgets one that is waiting.
func (a *App) stopUpdateCheck() {
	u := a.updates
	if u.timer != nil {
		u.timer.Stop()
		u.timer = nil
	}
	u.deferred = false
}

// updateCheckDue runs the automatic check that came due and arms the next, or, while the
// window is in the background, keeps it for when the window is active again.
func (a *App) updateCheckDue() {
	u := a.updates
	if u.stopped || !u.auto {
		return
	}
	if a.shownTab().windowInactive {
		u.deferred = true
		return
	}
	a.checkForUpdates(false)
	a.scheduleUpdateCheck(u.every)
}

// resumeUpdateCheck runs the automatic check that came due while the window was in the
// background. The window calls it when it is activated.
func (a *App) resumeUpdateCheck() {
	u := a.updates
	if u == nil || !u.deferred {
		return
	}
	u.deferred = false
	a.updateCheckDue()
}

// stopUpdates is the window closing: no check is armed again, a download stops, and an
// application a patch rebuilt is deleted, since nothing will install it.
func (a *App) stopUpdates() {
	u := a.updates
	if u == nil {
		return
	}
	u.stopped = true
	a.stopUpdateCheck()
	u.mu.Lock()
	cancel, payload := u.cancel, u.payload
	u.payload = ""
	u.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	a.removeUpdatePayload(payload)
}

// checkForUpdates reads the feed, unless a step is under way. asked says the user started
// it: only then does a failure show on the page, and only a check nobody asked for gives a
// notice.
func (a *App) checkForUpdates(asked bool) {
	u := a.updates
	u.mu.Lock()
	source := u.source
	busy := u.status.Checking || u.status.Downloading || u.status.Installing
	u.mu.Unlock()
	if source == nil || busy {
		return
	}
	if asked {
		a.performed("updates.check", surfaceButton)
	}
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		s.Checking = true
		if asked {
			s.Failure = ""
		}
	})
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), updateCheckTimeout)
		defer cancel()
		feed, err := source.Check(ctx)
		var asset appupdate.Asset
		if err == nil && feed != nil {
			asset, err = feed.Asset(runtime.GOOS, runtime.GOARCH)
		}
		a.post(func(a *App) { a.updateChecked(asked, feed, asset, err) })
	}()
}

// updateChecked takes in what a check found: nothing newer, or a version to update to.
// A download of another version is forgotten, since Update would install the wrong one, and
// an application a patch rebuilt for it is deleted.
func (a *App) updateChecked(asked bool, feed *appupdate.Feed, asset appupdate.Asset, err error) {
	u := a.updates
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("update_check", err))
		a.changeUpdate(func(s *settingswindow.UpdateStatus) {
			s.Checking = false
			if asked {
				s.Failure = err.Error()
			}
		})
		return
	}
	version := ""
	if feed != nil {
		version = feed.Latest.Version
	}
	now := time.Now()
	u.checkedAt = now
	var stale string
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		// changeUpdate holds u.mu, which guards what the check found too.
		if u.feed == nil || feed == nil || u.feed.Latest.Version != version {
			u.artifact = ""
			stale, u.payload = u.payload, ""
		}
		u.feed, u.asset = feed, asset
		s.Checking, s.Failure, s.LastChecked = false, "", now
		s.Available, s.NotesURL, s.UpToDate = version, "", feed == nil
		s.Ready = u.artifact != "" || u.payload != ""
		s.Delta, s.DeltaSize, s.FullSize = false, 0, 0
		if feed != nil {
			s.NotesURL, s.FullSize = feed.Latest.NotesURL, asset.Size
			if patch, ok := a.updatePatch(asset, version); ok {
				s.Delta, s.DeltaSize = true, patch.Size
			}
		}
	})
	a.removeUpdatePayload(stale)
	a.saveSettings()
	if version == "" || version == u.announced {
		return
	}
	// A version the user just saw on the page needs no notice later.
	u.announced = version
	if !asked {
		a.shownTab().notifyInfo(a.text.Updates.Available(version))
	}
}

// updateNow is Update: it installs the verified download or the rebuilt application, or
// downloads the available version first and installs it once verified.
func (a *App) updateNow() {
	u := a.updates
	u.mu.Lock()
	busy := u.status.Checking || u.status.Downloading || u.status.Installing
	ready, available := u.artifact != "" || u.payload != "", u.feed != nil
	u.mu.Unlock()
	if busy || !available {
		return
	}
	a.performed("updates.update", surfaceButton)
	if ready {
		a.installUpdate()
		return
	}
	a.downloadUpdate()
}

// cancelUpdate stops the download under way. Applying a patch cannot be interrupted, so
// the page offers no Cancel while it runs.
func (a *App) cancelUpdate() {
	u := a.updates
	u.mu.Lock()
	cancel, applying := u.cancel, u.status.Applying
	u.mu.Unlock()
	if cancel != nil && !applying {
		cancel()
		a.performed("updates.cancel", surfaceButton)
	}
}

// updatePatch is the patch the feed lists from the running version to version, unless a
// patch to that version already failed. The caller holds u.mu.
func (a *App) updatePatch(asset appupdate.Asset, version string) (appupdate.Patch, bool) {
	if a.version == "" || a.updates.noDelta == version {
		return appupdate.Patch{}, false
	}
	return asset.PatchFrom(a.version)
}

// removeUpdatePayload deletes an application a patch rebuilt in the temporary directory. A
// deletion that fails leaves a copy the system cleans up later, so it is logged and nothing
// else.
func (a *App) removeUpdatePayload(payload string) {
	if payload == "" {
		return
	}
	if err := removeUpdateDir(payload); err != nil {
		a.emit(core.LevelWarn, deltaCleanupFailedEvent, logwindow.ErrorFields(err))
	}
}

// deltaFellBack logs the step of a delta update that failed and skips the patch to version
// from then on, so the next download is the full archive. It runs on any goroutine.
func (a *App) deltaFellBack(stage, version string, err error) {
	fields := logwindow.ErrorFields(err)
	fields["stage"] = stage
	a.emit(core.LevelWarn, deltaFallbackEvent, fields)
	a.updates.mu.Lock()
	a.updates.noDelta = version
	a.updates.mu.Unlock()
}

// downloadUpdate fetches the available version into the user's cache directory and installs
// it once verified: the patch from the running version when the feed lists one, else the
// full archive.
func (a *App) downloadUpdate() {
	u := a.updates
	u.mu.Lock()
	source, feed, asset := u.source, u.feed, u.asset
	var patch appupdate.Patch
	delta, fellBack := false, false
	if feed != nil {
		patch, delta = a.updatePatch(asset, feed.Latest.Version)
		fellBack = u.noDelta == feed.Latest.Version
	}
	u.mu.Unlock()
	if source == nil || feed == nil {
		return
	}
	cache, err := updateCacheDir()
	if err != nil {
		a.updateFailed(err)
		return
	}
	dir := filepath.Join(cache, "Lithe", "Updates", feed.Latest.Version)
	ctx, cancel := context.WithCancel(context.Background())
	u.mu.Lock()
	u.cancel = cancel
	u.mu.Unlock()
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		s.Downloading, s.Applying, s.Progress, s.Failure = true, false, 0, ""
		s.Delta, s.FellBack = delta, fellBack
	})
	go func() {
		defer cancel()
		var artifact, payload string
		err := os.MkdirAll(dir, 0o700)
		if err == nil && delta {
			payload, err = a.fetchDelta(ctx, source, feed.Latest.Version, asset, patch, dir)
			if err != nil && ctx.Err() == nil {
				// A patch that cannot be used is replaced by the full archive, which the
				// page says it is downloading now.
				a.post(func(a *App) {
					a.changeUpdate(func(s *settingswindow.UpdateStatus) {
						s.Delta, s.Applying, s.FellBack, s.Progress = false, false, true, 0
					})
				})
				err = nil
			}
		}
		if err == nil && payload == "" {
			artifact, err = source.Download(ctx, asset, dir, a.updateProgress())
		}
		a.post(func(a *App) { a.updateDownloaded(feed, artifact, payload, err) })
	}()
}

// fetchDelta downloads the patch to version and rebuilds the new application from the
// installed one with it, returning the rebuilt copy. It runs on the download goroutine. A
// step that fails is logged, with what made it fail, before the caller falls back to the full
// archive; a cancel is not a failure.
func (a *App) fetchDelta(ctx context.Context, source updateSource, version string, asset appupdate.Asset, patch appupdate.Patch, dir string) (string, error) {
	path, err := source.DownloadPatch(ctx, asset, patch, dir, a.updateProgress())
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", ctxErr
	}
	if err != nil {
		a.deltaFellBack(deltaStageDownload, version, err)
		return "", err
	}
	// Applying reads every file of the installed application and cannot be interrupted, so
	// the page shows it without a progress bar or Cancel.
	a.post(func(a *App) {
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Applying, s.Progress = true, 1 })
	})
	payload, err := applyUpdatePatch(path, buildinfo.UpdateApp, a.version, version)
	if ctxErr := ctx.Err(); ctxErr != nil {
		// The window closed or the download was cancelled while the patch applied: nothing
		// will install the copy.
		a.removeUpdatePayload(payload)
		return "", ctxErr
	}
	if err != nil {
		a.deltaFellBack(deltaStageApply, version, err)
		return "", err
	}
	return payload, nil
}

// updateProgress is the progress callback of one download. Progress arrives on the download
// goroutine: it repaints the settings window through post, once per whole percent.
func (a *App) updateProgress() func(done, total int64) {
	shown := -1
	return func(done, total int64) {
		if total <= 0 || int(done*100/total) == shown {
			return
		}
		shown = int(done * 100 / total)
		progress := float32(done) / float32(total)
		a.post(func(a *App) { a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Progress = progress }) })
	}
}

// updateDownloaded takes in the end of a download: a cancel puts the row back as it was, a
// verified archive or a rebuilt application is installed at once. A rebuilt copy nothing will
// install, because the window closed or a check found another version, is deleted.
func (a *App) updateDownloaded(feed *appupdate.Feed, artifact, payload string, err error) {
	u := a.updates
	u.mu.Lock()
	u.cancel = nil
	current := u.feed == feed && !u.stopped
	stale := payload
	if err == nil && current {
		u.artifact, u.payload, stale = artifact, payload, ""
	}
	u.mu.Unlock()
	a.removeUpdatePayload(stale)
	switch {
	case errors.Is(err, context.Canceled):
		// log-exempt: 用户取消下载或窗口关闭，不是失败。
		a.changeUpdate(func(s *settingswindow.UpdateStatus) {
			s.Downloading, s.Applying, s.FellBack, s.Progress = false, false, false, 0
		})
	case err != nil:
		a.updateFailed(err)
	case !current:
		// A check replaced the version while it downloaded: Update starts again from it.
		a.changeUpdate(func(s *settingswindow.UpdateStatus) {
			s.Downloading, s.Applying, s.FellBack, s.Progress = false, false, false, 0
		})
	default:
		a.changeUpdate(func(s *settingswindow.UpdateStatus) {
			s.Downloading, s.Applying, s.FellBack, s.Ready, s.Progress = false, false, false, true, 1
		})
		a.installUpdate()
	}
}

// installUpdate closes every project tab the way quitting does, saving or asking about
// unsaved files, then hands the verified archive or the rebuilt application to the installer,
// which restarts into the new version. If a tab is not let go, nothing happens and Update
// installs on the next try; if the installer refuses, nothing was changed and the window
// stays.
//
// A rebuilt application is installed once. The installer copies it before it quits the
// window, and it is deleted then; one the installer refuses is deleted too, and Update
// downloads the full archive instead, unless the refusal would meet the archive as well.
func (a *App) installUpdate() {
	u := a.updates
	u.mu.Lock()
	ready := (u.artifact != "" || u.payload != "") && u.feed != nil
	u.mu.Unlock()
	if !ready || updateQuit(a) == nil {
		return
	}
	install := func() {
		// What to install is read again: a check may have replaced it while the tabs closed.
		u.mu.Lock()
		artifact, payload, asset, feed := u.artifact, u.payload, u.asset, u.feed
		u.payload = ""
		u.mu.Unlock()
		if artifact == "" && payload == "" || feed == nil {
			return
		}
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Installing, s.Failure = true, "" })
		options := appupdate.InstallOptions{Artifact: artifact, Payload: payload, Asset: asset, Version: feed.Latest.Version, App: buildinfo.UpdateApp}
		if runtime.GOOS != "darwin" {
			options.App = ""
		}
		quit := updateQuit(a)
		err := installUpdateArchive(options, func() {
			// The installer has copied the rebuilt application into its own staging
			// directory by now, and the window ends once quit returns.
			a.removeUpdatePayload(payload)
			quit()
		})
		if err == nil {
			return
		}
		a.removeUpdatePayload(payload)
		if payload == "" || errors.Is(err, appupdate.ErrManagedExternally) || errors.Is(err, appupdate.ErrNotWritable) {
			a.updateFailed(err)
			if payload != "" {
				a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Ready = false })
			}
			return
		}
		a.deltaFellBack(deltaStageInstall, feed.Latest.Version, err)
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Installing, s.Ready = false, false })
		a.downloadUpdate()
	}
	if a.sessions == nil {
		a.requestCloseProject(install)
		return
	}
	a.sessions.closeAll(install)
}

// updateFailed shows why a step the user started failed and logs it.
func (a *App) updateFailed(err error) {
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		s.Downloading, s.Applying, s.FellBack, s.Installing, s.Checking, s.Progress = false, false, false, false, false, 0
		s.Failure = err.Error()
	})
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("update", err))
}
