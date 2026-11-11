package workbench

import (
	"context"
	"crypto/ed25519"
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
// update package checks the Ed25519 signature, downloads the archive for this platform
// with its size and SHA-256 checked, and installs it, keeping the old application until
// the new one starts. The user starts every step from the Updates settings page; a check
// at startup, at most daily, only says that a version is available. The download lands in
// the user's cache directory, never in the installed application.

// updateCheckInterval is how often the startup check reads the feed.
const updateCheckInterval = 24 * time.Hour

// updater is the update state. The settings window reads it from its own thread, so the
// status is behind a lock; the steps run in goroutines and report through post.
type updater struct {
	mu       sync.Mutex
	status   settingswindow.UpdateStatus
	client   *appupdate.Client
	feed     *appupdate.Feed
	asset    appupdate.Asset
	artifact string
	cancel   context.CancelFunc
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
	u := &a.updates
	u.mu.Lock()
	defer u.mu.Unlock()
	status := u.status
	status.Configured = u.client != nil
	return status
}

// changeUpdate edits the status under the lock and repaints the settings window.
func (a *App) changeUpdate(change func(*settingswindow.UpdateStatus)) {
	u := &a.updates
	u.mu.Lock()
	change(&u.status)
	u.mu.Unlock()
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
}

// startUpdates makes the feed client and, when the user lets Lithe check on its own and
// the last check is a day old, checks once.
func (a *App) startUpdates() {
	a.updates.client = newUpdateClient(a.version)
	if a.updates.client == nil || !a.autoCheckUpdates() {
		return
	}
	if time.Since(a.settings.UpdatesCheckedAt) < updateCheckInterval {
		return
	}
	a.checkForUpdates(false)
}

// autoCheckUpdates is the setting, on unless the user turned it off.
func (a *App) autoCheckUpdates() bool { return !a.settings.UpdatesManual }

// checkForUpdates reads the feed. A manual check reports that nothing is newer; the
// startup check says only when a version is available.
func (a *App) checkForUpdates(manual bool) {
	u := &a.updates
	client := u.client
	if client == nil {
		return
	}
	a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Checking, s.Failure, s.UpToDate = true, "", false })
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		feed, err := client.Check(ctx)
		var asset appupdate.Asset
		if err == nil && feed != nil {
			asset, err = feed.Asset(runtime.GOOS, runtime.GOARCH)
		}
		a.post(func(a *App) {
			u.mu.Lock()
			u.feed, u.asset = feed, asset
			u.mu.Unlock()
			a.changeUpdate(func(s *settingswindow.UpdateStatus) {
				s.Checking = false
				if err != nil {
					s.Failure = err.Error()
					return
				}
				s.LastChecked = time.Now()
				s.Available, s.NotesURL, s.UpToDate = "", "", feed == nil
				if feed != nil {
					s.Available, s.NotesURL = feed.Latest.Version, feed.Latest.NotesURL
				}
			})
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("update_check", err))
				return
			}
			a.settings.UpdatesCheckedAt = time.Now()
			a.saveSettings()
			if feed != nil && !manual {
				a.notify(a.text.Updates.Available(feed.Latest.Version))
			}
		})
	}()
	a.performed("updates.check", surfaceButton)
}

// downloadUpdate fetches and verifies the archive of the available version into the
// user's cache directory.
func (a *App) downloadUpdate() {
	u := &a.updates
	u.mu.Lock()
	client, feed, asset := u.client, u.feed, u.asset
	u.mu.Unlock()
	if client == nil || feed == nil {
		return
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Failure = err.Error() })
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
		if err := os.MkdirAll(dir, 0o700); err != nil {
			a.post(func(a *App) { a.updateFailed(err) })
			return
		}
		// Progress arrives on the download goroutine: it repaints the settings window
		// through post, once per whole percent.
		shown := -1
		artifact, err := client.Download(ctx, asset, dir, func(done, total int64) {
			if total <= 0 || int(done*100/total) == shown {
				return
			}
			shown = int(done * 100 / total)
			progress := float32(done) / float32(total)
			a.post(func(a *App) { a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Progress = progress }) })
		})
		a.post(func(a *App) {
			if err != nil {
				a.updateFailed(err)
				return
			}
			u.mu.Lock()
			u.artifact = artifact
			u.mu.Unlock()
			a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Ready, s.Progress = false, true, 1 })
		})
	}()
	a.performed("updates.download", surfaceButton)
}

// installUpdate closes the project the way quitting does, saving or asking about unsaved
// files, then hands the verified archive to the installer, which restarts into the new
// version. If the installer refuses, nothing was changed and the window stays.
func (a *App) installUpdate() {
	u := &a.updates
	u.mu.Lock()
	artifact, asset, feed := u.artifact, u.asset, u.feed
	u.mu.Unlock()
	if artifact == "" || feed == nil || a.application == nil {
		return
	}
	a.performed("updates.install", surfaceButton)
	a.requestCloseProject(func() {
		a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Installing, s.Failure = true, "" })
		options := appupdate.InstallOptions{Artifact: artifact, Asset: asset, Version: feed.Latest.Version, App: buildinfo.UpdateApp}
		if runtime.GOOS != "darwin" {
			options.App = ""
		}
		if err := appupdate.Install(options, a.application.Quit); err != nil {
			a.updateFailed(err)
		}
	})
}

// updateFailed shows why a step failed and logs it.
func (a *App) updateFailed(err error) {
	a.changeUpdate(func(s *settingswindow.UpdateStatus) {
		s.Downloading, s.Installing, s.Checking = false, false, false
		s.Failure = err.Error()
	})
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("update", err))
}
