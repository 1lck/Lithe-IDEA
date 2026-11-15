package settingswindow

import (
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// UpdateStatus is what the updater is doing, as the update card shows it. The settings
// owner keeps it and the card reads it on every paint.
type UpdateStatus struct {
	// Configured is false for a build that has no update feed.
	Configured bool
	Checking   bool
	// Available is the newer version the feed offers, empty when none; NotesURL its
	// release notes.
	Available string
	NotesURL  string
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

// updatesPage is the Updates page of Appearance & Behavior: the running version over the
// update card the About page shows too.
func (w *window) updatesPage(c ui.C) {
	language := w.marketLanguage()
	w.pageScroll(c, pageUpdates, func() {
		w.card(c, i18n.Shared(language, "native.currentVersion"), "", func() {
			ui.Text(c, w.text.App.Version(w.ctrl.opts.Version, w.ctrl.opts.Stable)).FontSize(13).Color(w.pal.text)
		})
		w.updateCard(c)
	})
}

// updateCard is the update controls, as Motty lays them out: a switch for the automatic
// check, and one row that says what the last check found, with Check Now beside the one
// button that updates. Update downloads and verifies the new version, the delta update when
// the feed has one, then installs it and restarts; while it downloads, the same place cancels
// it.
func (w *window) updateCard(c ui.C) {
	language := w.marketLanguage()
	opts := &w.ctrl.opts
	p := &w.pal
	status := opts.UpdateStatus()
	// The card needs no ⓘ: the row under it says what a check does until one has run.
	w.card(c, i18n.Shared(language, "desktop.settings.updates.title"), "", func() {
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
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(p.line).MarginSides(4, 0, 4, 0)
		ui.Row(c).FillWidth().MinHeight(40).Items(ui.Center).Gap(12).Children(func() {
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.settings.updates.row")).FontSize(12).Color(p.text).Ellipsis()
				ui.Wrap(c, updateLine(language, status, w.text.App.Version(opts.Version, opts.Stable))).FontSize(11).Color(p.muted)
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
}

// updateButtons are the actions of the update row: Check Now, then Update once a version
// is available, which turns into Cancel while it downloads, then Release Notes. Applying a
// patch cannot be stopped, so it shows no Cancel.
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
		case status.Available != "":
			if ui.Button(c.Part("update"), i18n.Shared(language, "desktop.settings.updates.update")).Disabled(busy).Clicked() &&
				opts.UpdateNow != nil {
				opts.UpdateNow()
			}
		}
	})
}

// updateLine is what the update row says under its title: the step under way, what the last
// check found, or what the check does when nothing has happened yet. current is the running
// version as the pages show it, with its preview label. A delta update says so, with its
// size next to the full archive's while it is only available.
func updateLine(language i18n.Language, status UpdateStatus, current string) string {
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
	case status.Ready:
		return i18n.SharedFormat(language, "desktop.settings.updates.ready", map[string]string{"version": status.Available})
	case status.Available != "" && status.Delta && status.DeltaSize > 0 && status.FullSize > 0:
		return i18n.SharedFormat(language, "desktop.settings.updates.availableDelta", map[string]string{
			"version": status.Available, "size": byteSize(uint64(status.DeltaSize)), "full": byteSize(uint64(status.FullSize)),
		})
	case status.Available != "":
		return i18n.SharedFormat(language, "desktop.settings.updates.available", map[string]string{"version": status.Available})
	case status.UpToDate:
		return i18n.SharedFormat(language, "desktop.settings.updates.upToDate", map[string]string{"version": current})
	}
	return i18n.Shared(language, "desktop.settings.updates.help")
}
