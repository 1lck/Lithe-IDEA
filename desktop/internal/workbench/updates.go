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
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	appupdate "github.com/vivaui/viva/update"
)

// Updates come from the signed feed a release build names (buildinfo.UpdateFeedURL): Viva's
// update package checks the Ed25519 signature, downloads the archive for this platform with
// its size and SHA-256 checked, and installs it, keeping the old application until the new
// one starts. The download lands in the user's cache directory, never in the installed
// application.
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

// updateSource reads the feed and downloads a release: *appupdate.Client, or a test's.
type updateSource interface {
	Check(ctx context.Context) (*appupdate.Feed, error)
	Download(ctx context.Context, asset appupdate.Asset, dir string, progress func(done, total int64)) (string, error)
}

// installUpdateArchive replaces the application with a verified download and restarts it;
// a test replaces it.
var installUpdateArchive = appupdate.Install

// updateCacheDir is the user's cache directory, which downloads go under; a test replaces it.
var updateCacheDir = os.UserCacheDir

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
	cancel   context.CancelFunc

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

// stopUpdates is the window closing: no check is armed again, and a download stops.
func (a *App) stopUpdates() {
	u := a.updates
	if u == nil {
		return
	}
	u.stopped = true
	a.stopUpdateCheck()
	u.mu.Lock()
	cancel := u.cancel
	u.mu.Unlock()
	if cancel != nil {
		cancel()
	}
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
// A download of another version is forgotten, since Update would install the wrong one.
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
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		// changeUpdate holds u.mu, which guards what the check found too.
		if u.feed == nil || feed == nil || u.feed.Latest.Version != version {
			u.artifact = ""
		}
		u.feed, u.asset = feed, asset
		s.Checking, s.Failure, s.LastChecked = false, "", now
		s.Available, s.NotesURL, s.UpToDate, s.Ready = version, "", feed == nil, u.artifact != ""
		if feed != nil {
			s.NotesURL = feed.Latest.NotesURL
		}
	})
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

// updateNow is Update: it installs the verified download, or downloads the available
// version first and installs it once verified.
func (a *App) updateNow() {
	u := a.updates
	u.mu.Lock()
	busy := u.status.Checking || u.status.Downloading || u.status.Installing
	ready, available := u.artifact != "", u.feed != nil
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

// cancelUpdate stops the download under way.
func (a *App) cancelUpdate() {
	u := a.updates
	u.mu.Lock()
	cancel := u.cancel
	u.mu.Unlock()
	if cancel != nil {
		cancel()
		a.performed("updates.cancel", surfaceButton)
	}
}

// downloadUpdate fetches and verifies the archive of the available version into the
// user's cache directory, then installs it.
func (a *App) downloadUpdate() {
	u := a.updates
	u.mu.Lock()
	source, feed, asset := u.source, u.feed, u.asset
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
	a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Progress, s.Failure = true, 0, "" })
	go func() {
		defer cancel()
		var artifact string
		err := os.MkdirAll(dir, 0o700)
		if err == nil {
			// Progress arrives on the download goroutine: it repaints the settings window
			// through post, once per whole percent.
			shown := -1
			artifact, err = source.Download(ctx, asset, dir, func(done, total int64) {
				if total <= 0 || int(done*100/total) == shown {
					return
				}
				shown = int(done * 100 / total)
				progress := float32(done) / float32(total)
				a.post(func(a *App) { a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Progress = progress }) })
			})
		}
		a.post(func(a *App) { a.updateDownloaded(feed, artifact, err) })
	}()
}

// updateDownloaded takes in the end of a download: a cancel puts the row back as it was, a
// verified archive is installed at once.
func (a *App) updateDownloaded(feed *appupdate.Feed, artifact string, err error) {
	u := a.updates
	u.mu.Lock()
	u.cancel = nil
	current := u.feed == feed
	if err == nil && current {
		u.artifact = artifact
	}
	u.mu.Unlock()
	switch {
	case errors.Is(err, context.Canceled):
		// log-exempt: 用户取消下载或窗口关闭，不是失败。
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Progress = false, 0 })
	case err != nil:
		a.updateFailed(err)
	case !current:
		// A check replaced the version while it downloaded: Update starts again from it.
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Progress = false, 0 })
	default:
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Ready, s.Progress = false, true, 1 })
		a.installUpdate()
	}
}

// installUpdate closes every project tab the way quitting does, saving or asking about
// unsaved files, then hands the verified archive to the installer, which restarts into the
// new version. If a tab is not let go, nothing happens and Update installs on the next try;
// if the installer refuses, nothing was changed and the window stays.
func (a *App) installUpdate() {
	u := a.updates
	u.mu.Lock()
	artifact, asset, feed := u.artifact, u.asset, u.feed
	u.mu.Unlock()
	if artifact == "" || feed == nil || a.application == nil {
		return
	}
	install := func() {
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Installing, s.Failure = true, "" })
		options := appupdate.InstallOptions{Artifact: artifact, Asset: asset, Version: feed.Latest.Version, App: buildinfo.UpdateApp}
		if runtime.GOOS != "darwin" {
			options.App = ""
		}
		if err := installUpdateArchive(options, a.application.Quit); err != nil {
			a.updateFailed(err)
		}
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
		s.Downloading, s.Installing, s.Checking, s.Progress = false, false, false, 0
		s.Failure = err.Error()
	})
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("update", err))
}
