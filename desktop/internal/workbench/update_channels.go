package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	appupdate "github.com/vivaui/viva/update"
)

// A build updates from the channel it was packaged for (buildinfo.InstalledChannel) until the
// user switches to the other in Settings > Updates; the choice is saved (settings.UpdateChannel)
// and a build of the chosen channel, once installed, follows its own channel again. The two
// channels' versions are never compared with each other: an AutoBuild version is the release
// it builds towards with a pre-release suffix, 0.7.0-autobuild.<time>, which semantic
// versioning orders before the stable 0.7.0 it may be newer than. A check of the other channel
// therefore compares its feed with a version of its own choosing (updateTarget.against), which
// Viva's update.Config.Current is:
//
//   - Stable to AutoBuild, and AutoBuild back to stable now: 0.0.0, so the channel's latest
//     release is offered whatever it is, after the user confirmed the switch.
//   - AutoBuild back to stable, waiting: the release the build is on its way to, the running
//     version without its suffix, so only a stable release past it is offered.
//
// A release of the other channel replaces the build in full; its patches start from the other
// channel's previous release. Nothing is switched while a download or an install is under way,
// and a switch forgets what the last check found and checks the new channel at once.

// updateTarget is what a check reads: the feed of a channel, and the version its latest
// release has to be newer than to be offered.
type updateTarget struct {
	channel string
	feedURL string
	against string
	// cross says the channel is not the one the build was packaged for.
	cross bool
}

// waits says the target is AutoBuild's way back to stable that waits for a release past the
// running build.
func (t updateTarget) waits() bool {
	return t.cross && t.channel == buildinfo.ChannelStable && t.against != updateFromAnyVersion
}

// updateFromAnyVersion is the version a switch compares the other channel's feed with, so its
// latest release is offered whatever it is.
const updateFromAnyVersion = "0.0.0"

// channel is the channel updates come from: the one the user switched to, else the installed
// one. The caller holds u.mu.
func (u *updater) channel() string {
	if u.chosen != "" {
		return u.chosen
	}
	return u.installed
}

// feedURL is the feed of channel: the address the user set, else the channel's default. The
// caller holds u.mu.
func (u *updater) feedURL(channel string) string {
	if url := u.sources[channel]; url != "" {
		return url
	}
	return buildinfo.DefaultFeedURL(channel)
}

// wanted is what a check reads now, for a build running version. The caller holds u.mu.
func (u *updater) wanted(version string) updateTarget {
	channel := u.channel()
	target := updateTarget{channel: channel, feedURL: u.feedURL(channel), against: version}
	if channel != u.installed {
		target.cross, target.against = true, updateFromAnyVersion
		if channel == buildinfo.ChannelStable && !u.returnNow {
			target.against = releaseBase(version)
		}
	}
	return target
}

// releaseBase is the release an AutoBuild version builds towards (buildinfo.ReleaseBase), or
// any version for a build without one.
func releaseBase(version string) string {
	if version = buildinfo.ReleaseBase(version); version == "" {
		return updateFromAnyVersion
	}
	return version
}

// updateBusy says a download or an install is under way, during which neither the channel
// nor its feed changes. The caller holds u.mu.
func (u *updater) updateBusy() bool {
	return u.status.Downloading || u.status.Applying || u.status.Installing
}

// forget drops what the last check found, deleting an application a patch rebuilt for it,
// before a check of another feed. The caller holds u.mu and deletes the returned copy.
func (u *updater) forget() (stale string) {
	stale = u.payload
	u.target, u.source, u.feed, u.asset, u.artifact, u.payload = updateTarget{}, nil, nil, appupdate.Asset{}, "", ""
	u.notesFor = ""
	s := &u.status
	s.Available, s.NotesURL, s.UpToDate, s.Ready = "", "", false, false
	s.Cross, s.Skipped, s.Notes, s.NotesLoading, s.Manual, s.Waiting = false, false, "", false, "", ""
	s.Delta, s.DeltaSize, s.FullSize, s.Failure = false, 0, 0, ""
	u.dialog = false
	return stale
}

// setUpdateChannel switches the channel updates come from. now says, on the way back to
// stable from AutoBuild, that stable's latest release is wanted at once rather than the first
// one past the running build; restore that the settings kept when Lithe last left the channel
// come back when its release is installed. It does nothing while an update downloads or
// installs, and for a build that does not update.
func (a *App) setUpdateChannel(channel string, now, restore bool) {
	u := a.updates
	channel = buildinfo.KnownChannel(channel)
	u.mu.Lock()
	if channel == "" || u.installed == "" || u.updateBusy() {
		u.mu.Unlock()
		return
	}
	chosen := channel
	if chosen == u.installed {
		chosen = ""
	}
	returnNow := now && chosen == buildinfo.ChannelStable
	restore = restore && chosen != "" && u.snapshots[chosen] != ""
	if chosen == u.chosen && returnNow == u.returnNow && restore == u.restore {
		u.mu.Unlock()
		return
	}
	u.chosen, u.returnNow, u.restore = chosen, returnNow, restore
	stale := u.forget()
	u.mu.Unlock()
	a.removeUpdatePayload(stale)
	a.performed("updates.channel", surfaceButton)
	a.updatesChanged()
	a.saveSettings()
	a.checkForUpdates(true)
}

// setUpdateSource sets the feed channel reads to url, or back to the channel's default when
// url is empty or the default. An address the updater cannot read is ignored; the settings
// window refuses it before it gets here. It does nothing while an update downloads or
// installs.
func (a *App) setUpdateSource(channel, url string) {
	u := a.updates
	channel, url = buildinfo.KnownChannel(channel), strings.TrimSpace(url)
	if url == buildinfo.DefaultFeedURL(channel) {
		url = ""
	}
	if channel == "" || url != "" && !settingswindow.ValidUpdateSource(url) {
		return
	}
	u.mu.Lock()
	if u.updateBusy() || u.sources[channel] == url {
		u.mu.Unlock()
		return
	}
	if url == "" {
		delete(u.sources, channel)
	} else {
		u.sources[channel] = url
	}
	current := channel == u.channel()
	stale := ""
	if current {
		stale = u.forget()
	}
	u.mu.Unlock()
	a.removeUpdatePayload(stale)
	a.performed("updates.source", surfaceButton)
	a.updatesChanged()
	a.saveSettings()
	if current {
		a.checkForUpdates(true)
	}
}

// skipUpdate is Skip This Version: the available version of the channel shows no arrow or
// notice again, and a newer one does. A check the user asks for still finds it.
func (a *App) skipUpdate() {
	u := a.updates
	u.mu.Lock()
	version, channel := u.status.Available, u.target.channel
	if version == "" || channel == "" || u.updateBusy() {
		u.mu.Unlock()
		return
	}
	u.skipped[channel] = version
	u.status.Skipped = true
	u.dialog = false
	u.mu.Unlock()
	a.performed("updates.skip", surfaceButton)
	a.updatesChanged()
	a.saveSettings()
}

// showUpdateDialog opens the update dialog on the window the user sees, bringing it forward
// from behind the settings window. surface is where the user asked for it: the arrow on the
// title bar, the notice, or the settings.
func (a *App) showUpdateDialog(surface actionSurface) {
	u := a.updates
	u.mu.Lock()
	available := u.status.Available != ""
	u.dialog = available
	u.mu.Unlock()
	if !available {
		return
	}
	a.performed("updates.show", surface)
	if a.window != nil {
		a.window.Show()
	}
	a.updatesChanged()
}

// closeUpdateDialog is Later, or the dialog dismissed: the arrow stays, and a download under
// way goes on.
func (a *App) closeUpdateDialog() {
	if !a.updates.dialog {
		return
	}
	a.updates.dialog = false
	a.updatesChanged()
}

// openUpdateDownloads opens the downloads page, for an installation that cannot replace
// itself.
func (a *App) openUpdateDownloads() {
	a.performed("updates.downloads", surfaceButton)
	if err := openURL(buildinfo.DownloadsURL); err != nil {
		a.operationFailed("open_url", err)
	}
}

// updatesChanged repaints whatever shows the update state after a change outside the status:
// the dialog opened or closed, a version skipped.
func (a *App) updatesChanged() {
	a.changeUpdate(func(*settingswindow.UpdateStatus) {})
}

// updateArrowShown says the title bar shows the update arrow: a version is available that the
// user did not skip, or one they skipped is downloading or ready to install anyway.
func updateArrowShown(s settingswindow.UpdateStatus) bool {
	return s.Available != "" && (!s.Skipped || s.Downloading || s.Ready || s.Installing)
}
