package settingswindow

import (
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// UpdateStatus is what the updater is doing, as the update card shows it. The settings
// owner keeps it and the card reads it on every paint.
type UpdateStatus struct {
	// Configured is false for a build that cannot check: a local build, or a packaged one
	// without the keys its feeds are signed with. Local says it is a local build, which has no
	// channel.
	Configured bool
	Local      bool
	// Installed is the channel the build was packaged for, and Channel the one it updates
	// from, which the user may have switched to; Sources is the feed of each channel.
	Installed string
	Channel   string
	Sources   []UpdateSource
	// Waiting is the release AutoBuild waits to go past on its way back to stable: stable
	// offers a version only once one is newer than it. Empty unless the user switched to
	// stable from AutoBuild to wait.
	Waiting string
	// Restorable are the channels whose settings were kept when Lithe last left them, which
	// switching back can restore.
	Restorable []string
	Checking   bool
	// Available is the newer version the feed offers, empty when none; NotesURL its
	// release notes.
	Available string
	NotesURL  string
	// Cross says Available is on another channel than the installed one: it replaces the
	// build in full. Skipped says the user skipped it, so only a check they ask for shows it.
	Cross   bool
	Skipped bool
	// Notes are the release notes of Available, Markdown, empty when the feed has none for
	// it; NotesLoading says they are still on the way.
	Notes        string
	NotesLoading bool
	// Manual is why the installation cannot replace itself, which an install found: the
	// version has to be downloaded by hand.
	Manual string
	// UpToDate says the last check found nothing newer.
	UpToDate bool
	// Delta says Update downloads the patch from the running version, DeltaSize bytes,
	// instead of the full archive, FullSize bytes.
	Delta               bool
	DeltaSize, FullSize int64
	// Downloading lasts from the start of the download until the update is ready, through
	// Applying, the rebuilding of the new application from the patch, which cannot be
	// cancelled. FellBack says the patch could not be used and the full archive is coming.
	Downloading bool
	Applying    bool
	FellBack    bool
	// Progress is the share of the download done, 0 to 1.
	Progress float32
	// Ready says the verified download or the rebuilt application is waiting to be
	// installed.
	Ready      bool
	Installing bool
	Failure    string
	// LastChecked is when the feed was last read successfully.
	LastChecked time.Time
}

// busy says a download or an install is under way, during which neither the channel nor a
// feed can change.
func (s UpdateStatus) busy() bool {
	return s.Downloading || s.Applying || s.Installing
}

// source is the feed channel reads, its default when the status lists none.
func (s UpdateStatus) source(channel string) UpdateSource {
	for _, source := range s.Sources {
		if source.Channel == channel {
			return source
		}
	}
	return UpdateSource{Channel: channel, URL: buildinfo.DefaultFeedURL(channel)}
}

// UpdateSource is the feed one channel reads: URL, which Custom says the user set instead of
// the channel's default.
type UpdateSource struct {
	Channel string
	URL     string
	Custom  bool
}

// ValidUpdateSource says text can be a feed address: an absolute HTTPS URL with a host, which
// is all the updater accepts.
func ValidUpdateSource(text string) bool {
	parsed, err := url.Parse(strings.TrimSpace(text))
	return err == nil && parsed.Scheme == "https" && parsed.Host != "" && parsed.User == nil
}

// ChannelName is how the pages and the update dialog name an update channel.
func ChannelName(language i18n.Language, channel string) string {
	if channel == buildinfo.ChannelAutoBuild {
		return i18n.Shared(language, "desktop.updates.channel.autobuild")
	}
	return i18n.Shared(language, "desktop.updates.channel.stable")
}

// channelEntry is how the channel list of a build packaged for installed names channel.
// Picking the build's own channel saves no choice, updates follow the build, so its entry reads
// Automatic (<channel>); the other channel, which only an explicit switch picks, shows its name.
func channelEntry(language i18n.Language, channel, installed string) string {
	if channel == installed {
		return i18n.SharedFormat(language, "desktop.settings.updates.channelFollowsBuild", map[string]string{
			"channel": ChannelName(language, channel),
		})
	}
	return ChannelName(language, channel)
}

// feedRepository is how a feed is named to the user: owner/repository for a feed on GitHub,
// as the default ones are, else its host.
func feedRepository(address string) string {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" {
		return address
	}
	if parsed.Host == "github.com" {
		if parts := strings.Split(strings.Trim(parsed.Path, "/"), "/"); len(parts) >= 2 {
			return parts[0] + "/" + parts[1]
		}
	}
	return parsed.Host
}

// updatesDraft is the update card's unsaved edit: the feed address being typed for the
// channel updates come from, and a switch of channel waiting for the user to confirm it.
type updatesDraft struct {
	// source is the address field. sourceFor is the channel it edits and sourceShown the
	// address it was last loaded with: a field the user has not typed in follows the stored
	// address when it changes, and one they typed in keeps their text.
	source      ui.Field
	sourceFor   string
	sourceShown string
	// switching is the channel picked in the list, waiting for its confirmation; empty while
	// none is. restore is the confirmation's choice to bring back the settings kept when Lithe
	// last left that channel.
	switching string
	restore   bool
}

// loadSource shows the stored address of source in the field, unless the user is typing
// another for the same channel.
func (d *updatesDraft) loadSource(source UpdateSource) {
	typed := strings.TrimSpace(d.source.Text()) != d.sourceShown
	if d.sourceFor == source.Channel && (d.sourceShown == source.URL || typed) {
		return
	}
	d.sourceFor, d.sourceShown = source.Channel, source.URL
	d.source.SetText(source.URL)
}

// updateCard is the update controls, as Motty lays them out: a switch for the automatic
// check, and one row that says what the last check found, with Check Now beside the one
// button that moves on. A version found is shown in the update dialog of the workbench, with
// what it changed, before anything is downloaded; the card's button opens it. Once the update
// is downloaded the same place installs it and restarts, and while it downloads it cancels.
// Between the switch and that row are the channel updates come from and its feed. The card is
// on the About page, under the facts that already name the running version and build.
func (w *window) updateCard(c ui.C) {
	language := w.marketLanguage()
	opts := &w.ctrl.opts
	p := &w.pal
	status := opts.UpdateStatus()
	// The card needs no ⓘ: the row under it says what a check does until one has run.
	w.card(c, i18n.Shared(language, "desktop.settings.updates.title"), "", func() {
		if status.Local {
			ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.local")).FontSize(12).Color(p.muted).PadY(5)
			return
		}
		if !status.Configured {
			ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.notConfigured")).FontSize(12).Color(p.muted).PadY(5)
			return
		}
		autoLabel := i18n.Shared(language, "desktop.settings.updates.auto")
		w.settingsRow(c, autoLabel, i18n.Shared(language, "desktop.settings.updates.autoHelp"), func() {
			auto := w.sess.values.AutoCheckUpdates
			if ui.Switch(c.Part("auto"), &auto, "").Label(autoLabel).Changed() {
				if w.sess.finished.Load() || w.sess.values.AutoCheckUpdates == auto {
					return
				}
				w.sess.values.AutoCheckUpdates = auto
				if opts.SetAutoCheckUpdates != nil {
					opts.SetAutoCheckUpdates(auto)
				}
			}
		})
		w.updateChannelRows(c, language, status)
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(p.line).MarginSides(4, 0, 4, 0)
		ui.Row(c).FillWidth().MinHeight(40).Items(ui.Center).Gap(12).Children(func() {
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.settings.updates.row")).FontSize(12).Color(p.text).Ellipsis()
				ui.Wrap(c, UpdateLine(language, status, w.text.App.Version(opts.Version, opts.Stable))).FontSize(11).Color(p.muted)
			})
			w.updateButtons(c, language, status)
		})
		if status.Downloading && !status.Applying {
			ui.Progress(c, status.Progress).FillWidth().MarginSides(2, 0, 4, 0)
		}
		if status.Failure != "" {
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.settings.updates.failed", map[string]string{"reason": status.Failure})).
				FontSize(11).Color(p.danger).PadY(2)
		}
		if !status.LastChecked.IsZero() {
			when := status.LastChecked.Local().Format("2006-01-02 15:04")
			ui.Text(c, i18n.SharedFormat(language, "desktop.settings.updates.lastChecked", map[string]string{"time": when})).
				FontSize(11).Color(p.subtle).PadY(2)
		}
	})
	w.updateChannelDialog(c, language, status)
}

// updateChannelRows are the channel updates come from and the feed it reads. Picking the other
// channel than the build's asks first (updateChannelDialog), since its release replaces the
// build in full; going back to the build's own channel does not. The feed's address is saved
// only with Save, and Reset goes back to the channel's default. Neither changes while an
// update downloads or installs.
func (w *window) updateChannelRows(c ui.C, language i18n.Language, status UpdateStatus) {
	opts := &w.ctrl.opts
	p := &w.pal
	d := &w.updates
	busy := status.busy()
	channelLabel := i18n.Shared(language, "desktop.settings.updates.channel")
	w.settingsRow(c, channelLabel, i18n.Shared(language, "desktop.settings.updates.channelHelp"), func() {
		channel := status.Channel
		name := func(channel string) string { return channelEntry(language, channel, status.Installed) }
		if ui.Select(c.Part("channel"), &channel, buildinfo.Channels, name).Width(selectWidth).Label(channelLabel).
			Disabled(busy).Changed() && channel != status.Channel {
			w.pickUpdateChannel(channel, status)
		}
	})
	if busy {
		ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.channelBusy")).FontSize(11).Color(p.subtle).PadY(2)
	}
	source := status.source(status.Channel)
	d.loadSource(source)
	sourceLabel := i18n.SharedFormat(language, "desktop.settings.updates.source", map[string]string{
		"channel": ChannelName(language, status.Channel),
	})
	text := strings.TrimSpace(d.source.Text())
	valid := text == "" || ValidUpdateSource(text)
	w.settingsRow(c, sourceLabel, i18n.Shared(language, "desktop.settings.updates.sourceHelp"), func() {
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Center).Children(func() {
			ui.TextField(c.Part("source"), &d.source, sourceLabel, buildinfo.DefaultFeedURL(status.Channel)).
				Grow(1).MinWidth(0).Disabled(busy)
			if ui.Button(c.Part("source-save"), i18n.Shared(language, "desktop.settings.updates.sourceSave")).Outline().Small().
				Disabled(busy || !valid || text == source.URL).Clicked() && opts.SetUpdateSource != nil {
				saved := text
				if saved == "" {
					saved = buildinfo.DefaultFeedURL(status.Channel)
					d.source.SetText(saved)
				}
				d.sourceShown = saved
				opts.SetUpdateSource(status.Channel, text)
			}
		})
	})
	switch {
	case !valid:
		ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.sourceInvalid")).FontSize(11).Color(p.danger).PadY(2)
	case !source.Custom:
		ui.Wrap(c, i18n.SharedFormat(language, "desktop.settings.updates.sourceDefault", map[string]string{
			"repo": feedRepository(source.URL),
		})).FontSize(11).Color(p.subtle).PadY(2)
	default:
		// Restore Default sits under the field, not beside it, so the address keeps the width.
		ui.Row(c).Gap(6).Items(ui.Center).PadY(2).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.sourceCustom")).FontSize(11).Color(p.subtle).Shrink(1).MinWidth(0)
			if ui.Button(c.Part("source-reset"), i18n.Shared(language, "desktop.settings.updates.sourceReset")).
				Link().XSmall().Disabled(busy).Clicked() && opts.SetUpdateSource != nil {
				d.sourceShown = buildinfo.DefaultFeedURL(status.Channel)
				d.source.SetText(d.sourceShown)
				opts.SetUpdateSource(status.Channel, "")
			}
		})
	}
}

// pickUpdateChannel takes the channel picked in the list: the build's own at once, the other
// once the user confirms it.
func (w *window) pickUpdateChannel(channel string, status UpdateStatus) {
	opts := &w.ctrl.opts
	if channel == status.Installed {
		if opts.SetUpdateChannel != nil {
			opts.SetUpdateChannel(channel, false, false)
		}
		return
	}
	// Keeping the current settings is what happens without a word, so it is the default.
	w.updates.switching, w.updates.restore = channel, false
}

// updateChannelDialog asks before updates come from the other channel than the build's. To
// AutoBuild it says what AutoBuild is; back to stable from AutoBuild it offers to wait for the
// first stable release past the build, which never goes back to an older version, or to take
// stable's latest release at once. When Lithe kept the settings it had when it last left that
// channel, it offers to bring them back with the new build.
func (w *window) updateChannelDialog(c ui.C, language i18n.Language, status UpdateStatus) {
	d := &w.updates
	if d.switching == "" {
		return
	}
	opts := &w.ctrl.opts
	channel := d.switching
	toStable := channel == buildinfo.ChannelStable
	title := i18n.Shared(language, "desktop.settings.updates.toAutoBuild.title")
	body := i18n.Shared(language, "desktop.settings.updates.toAutoBuild.body")
	if toStable {
		title = i18n.Shared(language, "desktop.settings.updates.toStable.title")
		body = i18n.SharedFormat(language, "desktop.settings.updates.toStable.body", map[string]string{
			"version": buildinfo.ReleaseBase(opts.Version),
		})
	}
	restorable := slices.Contains(status.Restorable, channel)
	busy := status.busy()
	open := true
	choice := ""
	var content func()
	if restorable {
		content = func() {
			ui.Column(c).FillWidth().Gap(4).Children(func() {
				label := i18n.SharedFormat(language, "desktop.settings.updates.restore", map[string]string{
					"channel": ChannelName(language, channel),
				})
				ui.Checkbox(c.Part("restore"), &d.restore, label)
				ui.Wrap(c, i18n.Shared(language, "desktop.settings.updates.restoreHelp")).FontSize(11).Color(w.pal.muted).PadX(24)
			})
		}
	}
	closed := ui.Modal(c.Part("update-channel"), &open, title, ui.ModalSpec{Description: body, Width: 480}, content, func() {
		if ui.Button(c.Part("cancel"), w.text.Settings.Cancel).Outline().Clicked() {
			choice = "cancel"
		}
		if !toStable {
			if ui.Button(c.Part("confirm"), i18n.Shared(language, "desktop.settings.updates.toAutoBuild.confirm")).Disabled(busy).AutoFocus().Clicked() {
				choice = "switch"
			}
			return
		}
		if ui.Button(c.Part("now"), i18n.Shared(language, "desktop.settings.updates.toStable.now")).Outline().Disabled(busy).Clicked() {
			choice = "now"
		}
		// Waiting never installs a version older than the build, so it is the one Enter takes.
		if ui.Button(c.Part("wait"), i18n.Shared(language, "desktop.settings.updates.toStable.wait")).Disabled(busy).AutoFocus().Clicked() {
			choice = "switch"
		}
	})
	if closed {
		choice = "cancel"
	}
	switch choice {
	case "cancel":
		d.switching = ""
	case "switch", "now":
		d.switching = ""
		if opts.SetUpdateChannel != nil {
			opts.SetUpdateChannel(channel, choice == "now", restorable && d.restore)
		}
	}
}

// updateButtons are the actions of the update row: Release Notes, Check Now, then the step a
// version found offers. A version only available opens the update dialog, which shows what it
// changed before anything is downloaded; a downloaded one installs and restarts; a download
// under way cancels. Applying a patch cannot be stopped, so it shows no Cancel.
func (w *window) updateButtons(c ui.C, language i18n.Language, status UpdateStatus) {
	opts := &w.ctrl.opts
	busy := status.Checking || status.Downloading || status.Installing
	ui.Row(c).Shrink(0).Gap(8).Items(ui.Center).Children(func() {
		if status.NotesURL != "" && opts.OpenURL != nil {
			if ui.Button(c.Part("notes"), i18n.Shared(language, "desktop.settings.updates.notes")).Ghost().Clicked() {
				opts.OpenURL(status.NotesURL)
			}
		}
		if ui.Button(c.Part("check"), i18n.Shared(language, "desktop.settings.updates.check")).Outline().Disabled(busy).Clicked() &&
			opts.CheckForUpdates != nil {
			opts.CheckForUpdates()
		}
		switch {
		case status.Applying:
			// Nothing to offer: the rebuilt application installs as soon as it is done.
		case status.Downloading:
			if ui.Button(c.Part("cancel"), w.text.Settings.Cancel).Outline().Clicked() && opts.CancelUpdate != nil {
				opts.CancelUpdate()
			}
		case status.Ready && status.Manual == "":
			if ui.Button(c.Part("update"), i18n.Shared(language, "desktop.settings.updates.update")).Disabled(busy).Clicked() &&
				opts.UpdateNow != nil {
				opts.UpdateNow()
			}
		case status.Available != "" && opts.ShowUpdate != nil:
			if ui.Button(c.Part("view"), i18n.Shared(language, "desktop.updates.viewChanges")).Disabled(busy).Clicked() {
				opts.ShowUpdate()
			}
		}
	})
}

// UpdateLine is what the update row, and the update dialog while it works, say: the step
// under way, what the last check found, or what the check does when nothing has happened
// yet. current is the running version as the pages show it, with its preview label. A delta
// update says so, with its size next to the full archive's while it is only available.
func UpdateLine(language i18n.Language, status UpdateStatus, current string) string {
	percent := strconv.Itoa(int(status.Progress * 100))
	switch {
	case status.Installing:
		return i18n.Shared(language, "desktop.settings.updates.installing")
	case status.Applying:
		return i18n.SharedFormat(language, "desktop.settings.updates.applying", map[string]string{"version": status.Available})
	case status.Downloading && status.Delta:
		return i18n.SharedFormat(language, "desktop.settings.updates.downloadingDelta", map[string]string{
			"version": status.Available, "percent": percent,
		})
	case status.Downloading && status.FellBack:
		return i18n.SharedFormat(language, "desktop.settings.updates.downloadingFull", map[string]string{
			"version": status.Available, "percent": percent,
		})
	case status.Downloading:
		return i18n.SharedFormat(language, "desktop.settings.updates.downloading", map[string]string{
			"version": status.Available, "percent": percent,
		})
	case status.Checking:
		return i18n.Shared(language, "desktop.settings.updates.checking")
	case status.Manual != "":
		return status.Manual
	case status.Ready:
		return i18n.SharedFormat(language, "desktop.settings.updates.ready", map[string]string{"version": status.Available})
	case status.Available != "" && status.Skipped:
		return i18n.SharedFormat(language, "desktop.settings.updates.skipped", map[string]string{"version": status.Available})
	case status.Available != "" && status.Cross:
		return i18n.SharedFormat(language, "desktop.settings.updates.cross", map[string]string{
			"version": status.Available, "channel": ChannelName(language, status.Channel),
		})
	case status.Available != "" && status.Delta && status.DeltaSize > 0 && status.FullSize > 0:
		return i18n.SharedFormat(language, "desktop.settings.updates.availableDelta", map[string]string{
			"version": status.Available, "size": byteSize(uint64(status.DeltaSize)), "full": byteSize(uint64(status.FullSize)),
		})
	case status.Available != "":
		return i18n.SharedFormat(language, "desktop.settings.updates.available", map[string]string{"version": status.Available})
	case status.Waiting != "":
		return i18n.SharedFormat(language, "desktop.settings.updates.waiting", map[string]string{"version": status.Waiting})
	case status.UpToDate:
		return i18n.SharedFormat(language, "desktop.settings.updates.upToDate", map[string]string{"version": current})
	}
	return i18n.Shared(language, "desktop.settings.updates.help")
}
